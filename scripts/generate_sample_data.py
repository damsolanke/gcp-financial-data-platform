#!/usr/bin/env python3
"""Generate realistic sample financial data for the platform.

Reads JSON schemas from ../schemas/ to extract enum values and field names,
then generates deterministic, realistic financial events with seasonal
patterns, tier-based customer behaviour, and deliberate anomalies for
downstream testing and demonstration.

Usage:
    python generate_sample_data.py --seed 42 --output-dir ./data
    python generate_sample_data.py --seed 42 --output-dir ./data --publish
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Schema loading
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
SCHEMA_DIR = SCRIPT_DIR.parent / "schemas"


def load_schema(name: str) -> dict[str, Any]:
    """Load a JSON schema file by base name (without .json extension)."""
    path = SCHEMA_DIR / f"{name}.json"
    if not path.exists():
        raise FileNotFoundError(f"Schema not found: {path}")
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def extract_enum(schema: dict[str, Any], field: str) -> list[str]:
    """Extract enum values for a given field from a JSON schema."""
    props = schema.get("properties", {})
    if field not in props:
        raise KeyError(f"Field '{field}' not in schema properties")
    enum_vals = props[field].get("enum")
    if enum_vals is None:
        raise ValueError(f"Field '{field}' has no enum constraint")
    return list(enum_vals)


# ---------------------------------------------------------------------------
# Load schemas once at module level
# ---------------------------------------------------------------------------

REVENUE_SCHEMA = load_schema("revenue_transaction")
USAGE_SCHEMA = load_schema("usage_metric")
COST_SCHEMA = load_schema("cost_record")

PRODUCT_LINES: list[str] = extract_enum(REVENUE_SCHEMA, "product_line")
REGIONS: list[str] = extract_enum(REVENUE_SCHEMA, "region")
METRIC_TYPES: list[str] = extract_enum(USAGE_SCHEMA, "metric_type")
COST_CATEGORIES: list[str] = extract_enum(COST_SCHEMA, "category")

# Mapping of metric_type -> default unit (derived from schema description)
METRIC_UNITS: dict[str, str] = {
    "api_calls": "calls",
    "tokens_processed": "tokens",
    "compute_hours": "hours",
}

# ---------------------------------------------------------------------------
# Customer generation
# ---------------------------------------------------------------------------

TIER_DISTRIBUTION: dict[str, int] = {
    "free": 120,
    "growth": 60,
    "enterprise": 20,
}

TOTAL_CUSTOMERS = sum(TIER_DISTRIBUTION.values())  # 200

# Product lines allowed per tier
TIER_PRODUCT_LINES: dict[str, list[str]] = {
    "free": ["api_usage"],
    "growth": ["api_usage", "professional_services"],
    "enterprise": PRODUCT_LINES,  # all product lines
}

# Revenue ranges in cents per tier
TIER_REVENUE_RANGE: dict[str, tuple[int, int]] = {
    "free": (100, 5_000),
    "growth": (1_000, 50_000),
    "enterprise": (10_000, 500_000),
}


class Customer:
    """A generated customer with a deterministic ID and tier."""

    __slots__ = ("customer_id", "tier", "region", "product_lines")

    def __init__(
        self,
        customer_id: str,
        tier: str,
        region: str,
        product_lines: list[str],
    ) -> None:
        self.customer_id = customer_id
        self.tier = tier
        self.region = region
        self.product_lines = product_lines

    def __repr__(self) -> str:
        return f"Customer({self.customer_id!r}, tier={self.tier!r})"


def generate_customers(rng: random.Random) -> list[Customer]:
    """Create 200 customers with deterministic IDs and tier-based attributes."""
    customers: list[Customer] = []
    idx = 0
    for tier, count in TIER_DISTRIBUTION.items():
        for _ in range(count):
            # Deterministic UUID seeded by index
            cid = str(uuid.UUID(int=rng.getrandbits(128)))
            region = rng.choice(REGIONS)
            product_lines = TIER_PRODUCT_LINES[tier]
            customers.append(Customer(cid, tier, region, product_lines))
            idx += 1
    rng.shuffle(customers)
    return customers


# ---------------------------------------------------------------------------
# Anomaly configuration
# ---------------------------------------------------------------------------

# (day_offset, event_type, multiplier, description)
ANOMALIES: list[tuple[int, str, float, str]] = [
    (15, "revenue", 3.0, "big enterprise deal"),
    (30, "revenue", 0.3, "outage"),
    (45, "usage", 5.0, "viral moment"),
    (60, "revenue", 2.5, "revenue spike"),
    (75, "revenue", 0.2, "billing issue"),
]


def anomaly_multiplier(day_offset: int, event_type: str) -> float:
    """Return the anomaly multiplier for a given day and event type, or 1.0."""
    for a_day, a_type, a_mult, _ in ANOMALIES:
        if day_offset == a_day and a_type == event_type:
            return a_mult
    return 1.0


# ---------------------------------------------------------------------------
# Deterministic UUID helper
# ---------------------------------------------------------------------------


def make_uuid(rng: random.Random) -> str:
    """Generate a deterministic UUID-v4 from the seeded RNG."""
    return str(uuid.UUID(int=rng.getrandbits(128)))


# ---------------------------------------------------------------------------
# Timestamp helpers
# ---------------------------------------------------------------------------

BASE_DATE = datetime(2025, 1, 1, tzinfo=timezone.utc)
DURATION_DAYS = 90


def random_timestamp_in_day(
    rng: random.Random,
    day_start: datetime,
    *,
    peak_hours: tuple[int, int] | None = None,
) -> datetime:
    """Return a random timestamp within a 24-hour window.

    If *peak_hours* is given as (start_utc, end_utc), ~70% of timestamps
    will fall in that range, simulating business-hour concentration.
    """
    if peak_hours and rng.random() < 0.70:
        hour = rng.randint(peak_hours[0], peak_hours[1] - 1)
    else:
        hour = rng.randint(0, 23)

    minute = rng.randint(0, 59)
    second = rng.randint(0, 59)
    micro = rng.randint(0, 999_999)
    return day_start.replace(hour=hour, minute=minute, second=second, microsecond=micro)


def weekday_multiplier(dt: datetime) -> float:
    """Mon-Fri returns 1.0; Sat/Sun returns 0.5 (half volume)."""
    return 1.0 if dt.weekday() < 5 else 0.5


# ---------------------------------------------------------------------------
# Revenue transaction generation
# ---------------------------------------------------------------------------


def _effective_day_weights() -> float:
    """Compute the average weekday multiplier across the generation window.

    This lets us scale base_per_day so the total comes close to the target
    despite weekday/weekend volume differences.
    """
    total_weight = 0.0
    for d in range(DURATION_DAYS):
        dt = BASE_DATE + timedelta(days=d)
        total_weight += weekday_multiplier(dt)
    return total_weight / DURATION_DAYS


_AVG_WEEKDAY_MULT: float = _effective_day_weights()


def generate_revenue_transactions(
    rng: random.Random,
    customers: list[Customer],
    total: int,
) -> list[dict[str, Any]]:
    """Generate *total* revenue transaction events over 90 days."""
    events: list[dict[str, Any]] = []
    # Adjust for weekday/weekend mix so total ≈ requested count
    base_per_day = total / DURATION_DAYS / _AVG_WEEKDAY_MULT

    # Pre-compute per-tier customer lists
    tier_customers: dict[str, list[Customer]] = {
        tier: [c for c in customers if c.tier == tier]
        for tier in TIER_DISTRIBUTION
    }

    for day_offset in range(DURATION_DAYS):
        day_start = BASE_DATE + timedelta(days=day_offset)
        wd_mult = weekday_multiplier(day_start)
        # Weekdays get ~2x the base share, weekends ~1x, so effective ratio
        # across the week yields ~2:1.  We normalise later but keep volume
        # distribution correct relative to each other.
        anom_mult = anomaly_multiplier(day_offset, "revenue")
        day_count = max(1, int(base_per_day * wd_mult * anom_mult))

        _print_progress("Revenue transactions", day_offset, DURATION_DAYS)

        for _ in range(day_count):
            # Pick tier weighted: enterprise generates fewer but larger txns
            tier = rng.choices(
                ["free", "growth", "enterprise"],
                weights=[0.50, 0.35, 0.15],
                k=1,
            )[0]
            customer = rng.choice(tier_customers[tier])
            lo, hi = TIER_REVENUE_RANGE[tier]
            amount = rng.randint(lo, hi)

            ts = random_timestamp_in_day(rng, day_start)
            product_line = rng.choice(customer.product_lines)

            event: dict[str, Any] = {
                "transaction_id": make_uuid(rng),
                "timestamp": ts.isoformat(),
                "amount_cents": amount,
                "currency": "USD",
                "customer_id": customer.customer_id,
                "product_line": product_line,
                "region": customer.region,
            }
            events.append(event)

    _print_progress("Revenue transactions", DURATION_DAYS, DURATION_DAYS, done=True)
    return events


# ---------------------------------------------------------------------------
# Usage metric generation
# ---------------------------------------------------------------------------


def generate_usage_metrics(
    rng: random.Random,
    customers: list[Customer],
    total: int,
) -> list[dict[str, Any]]:
    """Generate *total* usage metric events over 90 days."""
    events: list[dict[str, Any]] = []
    base_per_day = total / DURATION_DAYS / _AVG_WEEKDAY_MULT

    for day_offset in range(DURATION_DAYS):
        day_start = BASE_DATE + timedelta(days=day_offset)
        wd_mult = weekday_multiplier(day_start)
        anom_mult = anomaly_multiplier(day_offset, "usage")
        day_count = max(1, int(base_per_day * wd_mult * anom_mult))

        _print_progress("Usage metrics", day_offset, DURATION_DAYS)

        for _ in range(day_count):
            customer = rng.choice(customers)

            # Metric type distribution: api_calls most common,
            # compute_hours mostly for enterprise.
            if customer.tier == "enterprise":
                metric_type = rng.choices(
                    METRIC_TYPES,
                    weights=[0.50, 0.30, 0.20],
                    k=1,
                )[0]
            else:
                metric_type = rng.choices(
                    METRIC_TYPES,
                    weights=[0.70, 0.25, 0.05],
                    k=1,
                )[0]

            # Quantity depends on metric type
            if metric_type == "api_calls":
                quantity = rng.randint(1, 10_000)
            elif metric_type == "tokens_processed":
                # Correlated with api_calls: ~100-5000 tokens per burst
                quantity = rng.randint(100, 50_000)
            else:  # compute_hours
                quantity = round(rng.uniform(0.01, 24.0), 2)

            unit = METRIC_UNITS[metric_type]

            ts = random_timestamp_in_day(
                rng,
                day_start,
                peak_hours=(14, 22),  # US business hours in UTC
            )

            event: dict[str, Any] = {
                "metric_id": make_uuid(rng),
                "timestamp": ts.isoformat(),
                "customer_id": customer.customer_id,
                "metric_type": metric_type,
                "quantity": quantity,
                "unit": unit,
            }
            events.append(event)

    _print_progress("Usage metrics", DURATION_DAYS, DURATION_DAYS, done=True)
    return events


# ---------------------------------------------------------------------------
# Cost record generation
# ---------------------------------------------------------------------------

COST_CENTERS: list[str] = [
    "engineering",
    "infrastructure",
    "data-platform",
    "ml-ops",
    "customer-support",
]

COST_VENDORS: dict[str, list[str]] = {
    "compute": ["Google Cloud", "Google Cloud"],
    "storage": ["Google Cloud", "Google Cloud"],
    "network": ["Google Cloud", "Cloudflare", "Fastly"],
    "personnel": [],
}

COST_DESCRIPTIONS: dict[str, list[str]] = {
    "compute": [
        "GKE cluster autopilot nodes",
        "Cloud Run ingestion service",
        "Dataflow pipeline workers",
        "Cloud Functions triggers",
    ],
    "storage": [
        "BigQuery storage fees",
        "Cloud Storage archival",
        "Bigtable SSD storage",
        "Artifact Registry images",
    ],
    "network": [
        "Inter-region egress",
        "Cloud CDN bandwidth",
        "VPC peering traffic",
        "External API egress",
    ],
    "personnel": [
        "Engineering salaries",
        "Contractor payments",
        "On-call stipends",
        "Training & certifications",
    ],
}


def generate_cost_records(
    rng: random.Random,
    total: int,
) -> list[dict[str, Any]]:
    """Generate *total* cost record events over 90 days.

    Patterns:
    - compute is the largest category
    - personnel is steady month-to-month
    - storage grows linearly over the window
    - network has occasional spikes
    """
    events: list[dict[str, Any]] = []
    base_per_day = total / DURATION_DAYS

    for day_offset in range(DURATION_DAYS):
        day_start = BASE_DATE + timedelta(days=day_offset)
        day_count = max(1, int(base_per_day))

        _print_progress("Cost records", day_offset, DURATION_DAYS)

        for _ in range(day_count):
            # Category distribution: compute dominant
            category = rng.choices(
                COST_CATEGORIES,
                weights=[0.40, 0.20, 0.15, 0.25],
                k=1,
            )[0]

            # Base amount in cents
            if category == "compute":
                amount = rng.randint(50_000, 500_000)
            elif category == "storage":
                # Linear growth: starts at 10K, grows ~2x by day 90
                growth_factor = 1.0 + (day_offset / DURATION_DAYS)
                amount = int(rng.randint(10_000, 50_000) * growth_factor)
            elif category == "network":
                amount = rng.randint(5_000, 100_000)
                # Random spikes (~5% chance)
                if rng.random() < 0.05:
                    amount *= rng.randint(3, 8)
            else:  # personnel
                # Steady: monthly recurring
                amount = rng.randint(200_000, 800_000)

            cost_center = rng.choice(COST_CENTERS)
            vendors = COST_VENDORS.get(category, [])
            description = rng.choice(COST_DESCRIPTIONS[category])

            ts = random_timestamp_in_day(rng, day_start)

            event: dict[str, Any] = {
                "record_id": make_uuid(rng),
                "timestamp": ts.isoformat(),
                "cost_center": cost_center,
                "category": category,
                "amount_cents": amount,
                "currency": "USD",
            }

            if vendors:
                event["vendor"] = rng.choice(vendors)
            event["description"] = description

            events.append(event)

    _print_progress("Cost records", DURATION_DAYS, DURATION_DAYS, done=True)
    return events


# ---------------------------------------------------------------------------
# Progress reporting
# ---------------------------------------------------------------------------


def _print_progress(
    label: str,
    current: int,
    total: int,
    *,
    done: bool = False,
) -> None:
    """Print a simple progress bar to stderr."""
    if done:
        sys.stderr.write(f"\r  {label}: {total}/{total} days [done]          \n")
        sys.stderr.flush()
        return

    if current % 5 != 0 and current != 0:
        return  # Only update every 5 days to reduce I/O

    bar_len = 30
    filled = int(bar_len * current / total) if total else 0
    bar = "#" * filled + "-" * (bar_len - filled)
    pct = int(100 * current / total) if total else 0
    sys.stderr.write(f"\r  {label}: [{bar}] {pct}% ({current}/{total} days)")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# File I/O
# ---------------------------------------------------------------------------


def write_jsonl(events: list[dict[str, Any]], path: Path) -> None:
    """Write a list of event dicts to a JSONL file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for event in events:
            fh.write(json.dumps(event, separators=(",", ":")) + "\n")
    print(f"  Wrote {len(events):,} events -> {path}")


# ---------------------------------------------------------------------------
# Pub/Sub publishing (optional)
# ---------------------------------------------------------------------------


def publish_to_pubsub(
    events: list[dict[str, Any]],
    topic_name: str,
    project_id: str = "local-project",
) -> None:
    """Publish events to a Pub/Sub emulator topic."""
    try:
        from google.cloud import pubsub_v1  # type: ignore[import-untyped]
    except ImportError:
        print(
            "ERROR: google-cloud-pubsub is not installed. "
            "Run: pip install google-cloud-pubsub",
            file=sys.stderr,
        )
        sys.exit(1)

    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(project_id, topic_name)

    # Ensure topic exists (emulator)
    try:
        publisher.create_topic(request={"name": topic_path})
        print(f"  Created topic: {topic_path}")
    except Exception:
        pass  # Already exists

    batch_size = 500
    total = len(events)
    for i in range(0, total, batch_size):
        batch = events[i : i + batch_size]
        futures = []
        for event in batch:
            data = json.dumps(event).encode("utf-8")
            future = publisher.publish(topic_path, data)
            futures.append(future)
        # Wait for batch to complete
        for f in futures:
            f.result()
        pct = min(100, int(100 * (i + len(batch)) / total))
        sys.stderr.write(f"\r  Publishing to {topic_name}: {pct}%")
        sys.stderr.flush()

    sys.stderr.write(f"\r  Published {total:,} events to {topic_name}          \n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------


def print_summary(
    revenue: list[dict[str, Any]],
    usage: list[dict[str, Any]],
    costs: list[dict[str, Any]],
    customers: list[Customer],
) -> None:
    """Print summary statistics to stdout."""
    sep = "=" * 60
    print(f"\n{sep}")
    print("  DATA GENERATION SUMMARY")
    print(sep)

    print("\n  Record counts:")
    print(f"    Revenue transactions:  {len(revenue):>10,}")
    print(f"    Usage metrics:         {len(usage):>10,}")
    print(f"    Cost records:          {len(costs):>10,}")
    print(f"    Total:                 {len(revenue) + len(usage) + len(costs):>10,}")

    print("\n  Date range:")
    print(f"    Start:  {BASE_DATE.date().isoformat()}")
    print(f"    End:    {(BASE_DATE + timedelta(days=DURATION_DAYS - 1)).date().isoformat()}")
    print(f"    Days:   {DURATION_DAYS}")

    print("\n  Anomalous days:")
    for day, etype, mult, desc in ANOMALIES:
        date = (BASE_DATE + timedelta(days=day)).date().isoformat()
        direction = "SPIKE" if mult > 1 else "DROP"
        print(f"    Day {day:>2} ({date}): {etype} {direction} {mult}x -- {desc}")

    print("\n  Customer tier breakdown:")
    tier_counts: dict[str, int] = {}
    for c in customers:
        tier_counts[c.tier] = tier_counts.get(c.tier, 0) + 1
    for tier, count in sorted(tier_counts.items()):
        print(f"    {tier:<12} {count:>4} customers")
    print(f"    {'TOTAL':<12} {len(customers):>4} customers")

    print("\n  Schema-derived enums:")
    print(f"    product_lines:  {PRODUCT_LINES}")
    print(f"    regions:        {REGIONS}")
    print(f"    metric_types:   {METRIC_TYPES}")
    print(f"    cost_categories:{COST_CATEGORIES}")

    print(f"\n{sep}\n")


# ---------------------------------------------------------------------------
# Main CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Generate realistic sample financial data for the platform.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python generate_sample_data.py\n"
            "  python generate_sample_data.py --seed 123 --output-dir /tmp/data\n"
            "  python generate_sample_data.py --publish\n"
        ),
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Random seed for reproducible output (default: 42).",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default="./data",
        help="Directory for JSONL output files (default: ./data).",
    )
    parser.add_argument(
        "--publish",
        action="store_true",
        default=False,
        help="Also publish events to the Pub/Sub emulator.",
    )
    return parser.parse_args()


def main() -> None:
    """Entry point: generate data, write files, optionally publish."""
    args = parse_args()
    output_dir = Path(args.output_dir)
    rng = random.Random(args.seed)

    print(f"Generating sample data (seed={args.seed}) ...")
    print(f"Output directory: {output_dir.resolve()}\n")

    # --- Customers ---
    customers = generate_customers(rng)
    print(f"  Generated {len(customers)} customers\n")

    # --- Events ---
    print("Generating events:\n")
    revenue = generate_revenue_transactions(rng, customers, total=100_000)
    usage = generate_usage_metrics(rng, customers, total=500_000)
    costs = generate_cost_records(rng, total=10_000)

    # --- Write JSONL ---
    print("\nWriting JSONL files:\n")
    write_jsonl(revenue, output_dir / "revenue_transactions.jsonl")
    write_jsonl(usage, output_dir / "usage_metrics.jsonl")
    write_jsonl(costs, output_dir / "cost_records.jsonl")

    # --- Write customer manifest ---
    customer_data = [
        {
            "customer_id": c.customer_id,
            "tier": c.tier,
            "region": c.region,
            "product_lines": c.product_lines,
        }
        for c in customers
    ]
    write_jsonl(customer_data, output_dir / "customers.jsonl")

    # --- Publish (optional) ---
    if args.publish:
        emulator_host = os.environ.get("PUBSUB_EMULATOR_HOST")
        if not emulator_host:
            print(
                "\nWARNING: --publish was set but PUBSUB_EMULATOR_HOST is not set.\n"
                "Set it to e.g. localhost:8085 for the emulator.\n",
                file=sys.stderr,
            )
            sys.exit(1)

        print(f"\nPublishing to Pub/Sub emulator at {emulator_host} ...\n")
        publish_to_pubsub(revenue, "financial-events-revenue")
        publish_to_pubsub(usage, "financial-events-usage")
        publish_to_pubsub(costs, "financial-events-costs")

    # --- Summary ---
    print_summary(revenue, usage, costs, customers)


if __name__ == "__main__":
    main()
