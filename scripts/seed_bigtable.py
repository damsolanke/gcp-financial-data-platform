#!/usr/bin/env python3
"""Seed the BigTable emulator with generated JSONL financial data.

Reads JSONL files produced by generate_sample_data.py and writes them into
the BigTable emulator using the row-key format:

    {event_type}#{reverse_timestamp_ms}#{event_id}

where reverse_timestamp_ms = 9999999999999 - unix_timestamp_ms.  This gives
natural reverse-chronological ordering within each event-type prefix scan.

Column families:
    event_data        -- single column "json" holding the raw JSON blob
    metadata          -- indexed fields extracted from the event for quick lookup
    processing_status -- tracks ingestion / processing timestamps

Usage:
    export BIGTABLE_EMULATOR_HOST=localhost:8086
    python seed_bigtable.py --input-dir ./data
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

MAX_REVERSE_TS: int = 9_999_999_999_999  # 13-digit ceiling for reverse ts

PROJECT_ID: str = os.environ.get("GCP_PROJECT_ID", "local-project")
INSTANCE_ID: str = os.environ.get("BIGTABLE_INSTANCE_ID", "financial-events")
TABLE_ID: str = os.environ.get("BIGTABLE_TABLE_ID", "events")

COLUMN_FAMILIES: list[str] = [
    "event_data",
    "metadata",
    "processing_status",
]

BATCH_SIZE: int = 1_000

# Event type -> (id field name, list of metadata fields to index)
EVENT_CONFIG: dict[str, dict[str, Any]] = {
    "revenue_transaction": {
        "id_field": "transaction_id",
        "metadata_fields": [
            "customer_id",
            "product_line",
            "region",
            "currency",
            "amount_cents",
        ],
    },
    "usage_metric": {
        "id_field": "metric_id",
        "metadata_fields": [
            "customer_id",
            "metric_type",
            "unit",
            "quantity",
        ],
    },
    "cost_record": {
        "id_field": "record_id",
        "metadata_fields": [
            "cost_center",
            "category",
            "currency",
            "amount_cents",
        ],
    },
}

# Mapping of JSONL filename (stem) -> event type key
FILE_TO_EVENT_TYPE: dict[str, str] = {
    "revenue_transactions": "revenue_transaction",
    "usage_metrics": "usage_metric",
    "cost_records": "cost_record",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def iso_to_unix_ms(iso_str: str) -> int:
    """Convert an ISO 8601 timestamp string to Unix milliseconds."""
    # Handle timezone-naive strings by assuming UTC
    dt = datetime.fromisoformat(iso_str)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def make_row_key(event_type: str, timestamp_iso: str, event_id: str) -> str:
    """Build a BigTable row key with reverse-chronological ordering.

    Format: {event_type}#{9999999999999 - unix_ms}#{event_id}
    """
    unix_ms = iso_to_unix_ms(timestamp_iso)
    reverse_ts = MAX_REVERSE_TS - unix_ms
    return f"{event_type}#{reverse_ts:013d}#{event_id}"


def _print_progress(label: str, current: int, total: int, *, done: bool = False) -> None:
    """Print a simple progress indicator to stderr."""
    if done:
        sys.stderr.write(f"\r  {label}: {total:,}/{total:,} rows [done]            \n")
        sys.stderr.flush()
        return

    if current % BATCH_SIZE != 0 and current != 0:
        return
    pct = int(100 * current / total) if total else 0
    sys.stderr.write(f"\r  {label}: {current:,}/{total:,} rows ({pct}%)")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# BigTable operations
# ---------------------------------------------------------------------------


def get_bigtable_client() -> Any:
    """Create and return a BigTable client connected to the emulator.

    Raises SystemExit if the emulator host is not configured.
    """
    emulator_host = os.environ.get("BIGTABLE_EMULATOR_HOST")
    if not emulator_host:
        print(
            "ERROR: BIGTABLE_EMULATOR_HOST is not set.\n"
            "Start the emulator and export BIGTABLE_EMULATOR_HOST=localhost:8086",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        from google.cloud import bigtable  # type: ignore[import-untyped]
    except ImportError:
        print(
            "ERROR: google-cloud-bigtable is not installed.\n"
            "Run: pip install google-cloud-bigtable",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"  Connecting to BigTable emulator at {emulator_host}")
    print(f"  Project: {PROJECT_ID}  Instance: {INSTANCE_ID}  Table: {TABLE_ID}")
    client = bigtable.Client(project=PROJECT_ID, admin=True)
    return client


def ensure_table(client: Any) -> Any:
    """Create the BigTable instance, table, and column families if needed.

    Returns the Table object ready for mutations.
    """
    from google.cloud.bigtable import column_family as cf_module  # type: ignore[import-untyped]

    instance = client.instance(INSTANCE_ID)

    # The emulator auto-creates instances, so we just get a reference
    table = instance.table(TABLE_ID)

    # Try to read existing column families
    try:
        existing_cfs = set(table.list_column_families().keys())
    except Exception:
        existing_cfs = set()

    # Create the table if it doesn't exist (emulator-compatible approach)
    if not existing_cfs:
        print(f"  Creating table '{TABLE_ID}' ...")
        # MaxVersions GC rule: keep only the latest version
        gc_rule = cf_module.MaxVersionsGCRule(1)
        column_families_spec = {cf: gc_rule for cf in COLUMN_FAMILIES}
        try:
            table.create(column_families=column_families_spec)
            print(f"  Created table with column families: {COLUMN_FAMILIES}")
        except Exception as exc:
            # Table might already exist; try to add missing CFs
            if "already exists" in str(exc).lower() or "AlreadyExists" in str(exc):
                print("  Table already exists, checking column families ...")
                existing_cfs = set(table.list_column_families().keys())
            else:
                raise
    else:
        print(f"  Table '{TABLE_ID}' exists with families: {sorted(existing_cfs)}")

    # Add any missing column families
    gc_rule = cf_module.MaxVersionsGCRule(1)
    for cf_name in COLUMN_FAMILIES:
        if cf_name not in existing_cfs:
            print(f"  Creating column family: {cf_name}")
            cf = table.column_family(cf_name, gc_rule=gc_rule)
            cf.create()

    return table


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    """Load all records from a JSONL file."""
    records: list[dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def seed_event_type(
    table: Any,
    event_type: str,
    records: list[dict[str, Any]],
) -> int:
    """Write records for a single event type into BigTable in batches.

    Returns the number of rows written.
    """
    config = EVENT_CONFIG[event_type]
    id_field: str = config["id_field"]
    metadata_fields: list[str] = config["metadata_fields"]

    label = f"{event_type} ({len(records):,} rows)"
    total = len(records)
    rows_written = 0
    batch_rows = []

    now_iso = datetime.now(timezone.utc).isoformat()

    for i, record in enumerate(records):
        _print_progress(label, i, total)

        event_id = record[id_field]
        timestamp_iso = record["timestamp"]
        row_key = make_row_key(event_type, timestamp_iso, event_id)

        row = table.direct_row(row_key)

        # event_data: raw JSON blob
        row.set_cell(
            "event_data",
            "json",
            json.dumps(record).encode("utf-8"),
        )

        # metadata: indexed fields for quick lookups
        for field in metadata_fields:
            if field in record:
                value = record[field]
                row.set_cell(
                    "metadata",
                    field,
                    str(value).encode("utf-8"),
                )

        # processing_status: ingestion timestamp
        row.set_cell(
            "processing_status",
            "ingested_at",
            now_iso.encode("utf-8"),
        )
        row.set_cell(
            "processing_status",
            "source",
            b"seed_bigtable.py",
        )

        batch_rows.append(row)

        # Flush batch
        if len(batch_rows) >= BATCH_SIZE:
            _flush_batch(table, batch_rows)
            rows_written += len(batch_rows)
            batch_rows = []

    # Final partial batch
    if batch_rows:
        _flush_batch(table, batch_rows)
        rows_written += len(batch_rows)

    _print_progress(label, total, total, done=True)
    return rows_written


def _flush_batch(table: Any, rows: list[Any]) -> None:
    """Mutate a batch of direct rows.

    Uses individual row commits since the emulator may not support
    MutateRows RPC fully.
    """
    for row in rows:
        row.commit()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Seed the BigTable emulator with generated JSONL data.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  export BIGTABLE_EMULATOR_HOST=localhost:8086\n"
            "  python seed_bigtable.py\n"
            "  python seed_bigtable.py --input-dir /tmp/data\n"
        ),
    )
    parser.add_argument(
        "--input-dir",
        type=str,
        default="./data",
        help="Directory containing JSONL files (default: ./data).",
    )
    parser.add_argument(
        "--project-id",
        type=str,
        default=None,
        help=f"GCP project ID (default: env GCP_PROJECT_ID or '{PROJECT_ID}').",
    )
    parser.add_argument(
        "--instance-id",
        type=str,
        default=None,
        help=f"BigTable instance ID (default: env BIGTABLE_INSTANCE_ID or '{INSTANCE_ID}').",
    )
    parser.add_argument(
        "--table-id",
        type=str,
        default=None,
        help=f"BigTable table ID (default: env BIGTABLE_TABLE_ID or '{TABLE_ID}').",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=BATCH_SIZE,
        help=f"Number of rows per write batch (default: {BATCH_SIZE}).",
    )
    return parser.parse_args()


def main() -> None:
    """Entry point: read JSONL files and write to BigTable emulator."""
    args = parse_args()
    input_dir = Path(args.input_dir)

    # Allow CLI overrides for project/instance/table
    global PROJECT_ID, INSTANCE_ID, TABLE_ID, BATCH_SIZE
    if args.project_id:
        PROJECT_ID = args.project_id
    if args.instance_id:
        INSTANCE_ID = args.instance_id
    if args.table_id:
        TABLE_ID = args.table_id
    BATCH_SIZE = args.batch_size

    if not input_dir.is_dir():
        print(f"ERROR: Input directory does not exist: {input_dir}", file=sys.stderr)
        sys.exit(1)

    # Discover JSONL files
    jsonl_files: dict[str, Path] = {}
    for stem, event_type in FILE_TO_EVENT_TYPE.items():
        path = input_dir / f"{stem}.jsonl"
        if path.exists():
            jsonl_files[event_type] = path
        else:
            print(f"  WARNING: Expected file not found: {path}")

    if not jsonl_files:
        print("ERROR: No JSONL files found. Run generate_sample_data.py first.", file=sys.stderr)
        sys.exit(1)

    print("\nBigTable Seeder")
    print(f"{'=' * 50}")
    print(f"  Input directory: {input_dir.resolve()}")
    print(f"  Files found:     {len(jsonl_files)}")
    print()

    # Connect and prepare table
    client = get_bigtable_client()
    table = ensure_table(client)
    print()

    # Seed each event type
    total_rows = 0
    start_time = time.monotonic()

    for event_type, path in jsonl_files.items():
        print(f"  Loading {path.name} ...")
        records = load_jsonl(path)
        print(f"  Loaded {len(records):,} records")

        rows = seed_event_type(table, event_type, records)
        total_rows += rows
        print()

    elapsed = time.monotonic() - start_time

    # Summary
    print(f"{'=' * 50}")
    print("  Seeding complete!")
    print(f"  Total rows written: {total_rows:,}")
    print(f"  Elapsed time:       {elapsed:.1f}s")
    print(f"  Throughput:         {total_rows / elapsed:,.0f} rows/s")
    print(f"{'=' * 50}\n")


if __name__ == "__main__":
    main()
