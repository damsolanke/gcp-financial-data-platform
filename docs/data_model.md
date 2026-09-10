# Data Model

This document describes every data entity in the platform, how schemas flow through the system, and the dbt model lineage from raw ingestion to reporting-ready marts.

---

## Schema Source of Truth

All event schemas are defined as JSON Schema Draft-07 files in the `schemas/` directory at the repository root. These are the canonical definitions that govern validation, documentation, and downstream expectations.

```
schemas/
├── revenue_transaction.json
├── usage_metric.json
└── cost_record.json
```

**How schemas flow through the system:**

1. **schemas/** -- The canonical JSON Schema definitions. All other copies derive from these.
2. **ingestion-service/internal/validator/schemas/** -- Copies embedded in the Go binary at build time. The ingestion service validates every incoming event against these schemas before publishing to Pub/Sub. `internal/handler/contract_test.go` fails if the copies drift from `schemas/` or if a published payload violates them.
3. **terraform/modules/bigquery** -- The `fdp_<env>_raw` landing tables (`raw_revenue_transactions`, `raw_usage_metrics`, `raw_cost_records`) have one column per schema property plus `ingestion_timestamp`; `timestamp` is kept as the published string.
4. **dbt_project/models/staging/schema.yml** -- Column-level expectations (not_null, accepted_values, unique, relationships) that mirror the JSON Schema constraints. dbt tests enforce these at the BigQuery layer.
5. **dbt_project/models/schema.yml** -- Mart-level documentation and tests that describe the transformed data model.

Changes to the schema require coordinated updates across all five locations (the Go test catches the first one automatically). This is deliberate -- financial data schemas should change rarely, and every downstream consumer must explicitly acknowledge the change.

---

## Event Schemas

### Revenue Transaction

The core billing event. Generated when a customer's API usage is metered and billed.

| Field | Type | Required | Constraints | Description |
|-------|------|----------|-------------|-------------|
| `transaction_id` | string (UUID) | Yes | Format: UUID | Unique identifier, used as deduplication key |
| `timestamp` | string (datetime) | Yes | Format: ISO 8601 | When the transaction occurred |
| `amount_cents` | integer | Yes | >0 (exclusive minimum) | Transaction amount in cents; always positive |
| `currency` | string | Yes | Pattern: `^[A-Z]{3}$` | ISO 4217 currency code (USD, EUR, GBP, JPY) |
| `customer_id` | string | Yes | minLength: 1 | Customer identifier, links to usage metrics |
| `product_line` | string (enum) | Yes | `api_usage`, `enterprise_license`, `professional_services` | Revenue classification |
| `region` | string (enum) | Yes | `us-east`, `us-west`, `eu-west`, `ap-southeast` | Geographic origin |
| `metadata` | object | No | additionalProperties: true | Arbitrary key-value pairs (BigQuery `JSON` column in the raw table) |

**Design note:** Amounts are stored in cents as integers to avoid floating-point precision issues. The `cents_to_dollars` dbt macro handles presentation-layer conversion: `ROUND(CAST(amount AS FLOAT64) / 100.0, 2)`.

**Timestamps:** `timestamp` is RFC 3339. The two producers in this repository emit two shapes -- `2025-01-15T10:30:00Z` (hand-written clients, README examples) and `2025-01-15T10:30:00.123456+00:00` (`scripts/generate_sample_data.py`, Python `isoformat()`). Both validate against `format: date-time`, and the dbt `parse_event_timestamp` macro (`%Y-%m-%dT%H:%M:%E*S%Ez`, with a trailing `Z` normalised to `+00:00`) parses both.

### Usage Metric

Tracks customer consumption of platform resources. Used for tier classification and unit economics.

| Field | Type | Required | Constraints | Description |
|-------|------|----------|-------------|-------------|
| `metric_id` | string (UUID) | Yes | Format: UUID | Unique identifier, used as deduplication key |
| `timestamp` | string (datetime) | Yes | Format: ISO 8601 | When the metric was recorded |
| `customer_id` | string | Yes | minLength: 1 | Links to revenue transactions |
| `metric_type` | string (enum) | Yes | `api_calls`, `tokens_processed`, `compute_hours` | What is being measured |
| `quantity` | number | Yes | >= 0 | Amount of usage; non-negative |
| `unit` | string | Yes | minLength: 1 | Unit of measurement (calls, tokens, hours) |

**Design note:** The `customer_id` field creates a referential link to revenue transactions. The dbt staging model enforces this with a `relationships` test (severity: warn, not error, because usage can be recorded before the first billing event).

### Cost Record

Internal operational cost tracking. Feeds cost attribution and unit economics calculations.

| Field | Type | Required | Constraints | Description |
|-------|------|----------|-------------|-------------|
| `record_id` | string (UUID) | Yes | Format: UUID | Unique identifier, used as deduplication key |
| `timestamp` | string (datetime) | Yes | Format: ISO 8601 | When the cost was incurred |
| `cost_center` | string | Yes | minLength: 1 | Responsible team/department |
| `category` | string (enum) | Yes | `compute`, `storage`, `network`, `personnel` | Expenditure type |
| `amount_cents` | integer | Yes | (no minimum) | Cost in cents; may be negative for credits/refunds |
| `currency` | string | Yes | Pattern: `^[A-Z]{3}$` | ISO 4217 currency code |
| `vendor` | string | No | | External vendor name |
| `description` | string | No | | Human-readable cost description |

**Design note:** Unlike revenue transactions, `amount_cents` can be negative (credits, refunds). The `cost_center` field links to the `cost_center_hierarchy` seed table for department/division enrichment.

---

## dbt Model Lineage

```
                                SEEDS
                    ┌──────────────────────────────┐
                    │ currency_exchange_rates.csv   │
                    │ product_line_mapping.csv      │
                    │ cost_center_hierarchy.csv     │
                    └──────────────┬───────────────┘
                                   │
    RAW SOURCES                    │
    ┌──────────────┐               │
    │ raw_revenue  │               │
    │ raw_usage    │               │
    │ raw_cost     │               │
    └──────┬───────┘               │
           │                       │
    STAGING (dedup + type cast)    │
    ┌──────────────────────┐       │
    │ stg_revenue_trans    │       │
    │ stg_usage_metrics    │       │
    │ stg_cost_records     │       │
    └──────────┬───────────┘       │
               │                   │
    INTERMEDIATE (business logic)  │
    ┌──────────────────────────────┤
    │ int_daily_revenue            │ (joins currency rates)
    │ int_customer_usage_agg       │
    │ int_cost_by_center           │ (joins cost hierarchy)
    └──────────┬───────────────────┘
               │
    MARTS (reporting-ready)
    ┌─────────────────────────────────────┐
    │ FINANCE                             │
    │  fct_daily_revenue_summary          │ (DoD, WoW, MTD)
    │  fct_monthly_cost_attribution       │ (category %)
    │  fct_revenue_by_product_region      │ (cross-tab)
    │                                     │
    │ ANALYTICS                           │
    │  fct_customer_usage_report          │ (tier class)
    │  fct_unit_economics                 │ (gross margin)
    └─────────────────────────────────────┘
```

### Staging Models

All staging models follow the same pattern: deduplicate by primary key (latest `ingestion_timestamp` wins), parse the ISO 8601 string with the `parse_event_timestamp` macro, extract DATE for partitioning, generate a deterministic surrogate key, and tag with the source system identifier. They are views in `fdp_<env>_staging` over the `fdp_<env>_raw` landing tables.

#### stg_revenue_transactions

| Column | Type | Source | Transformation |
|--------|------|--------|----------------|
| `transaction_id` | STRING | `raw_revenue_transactions.transaction_id` | Pass-through |
| `event_timestamp` | TIMESTAMP | `raw_revenue_transactions.timestamp` | `parse_event_timestamp` macro (fractional seconds + offset) |
| `event_date` | DATE | Derived | `DATE(event_timestamp)` |
| `amount_cents` | INT64 | `raw_revenue_transactions.amount_cents` | Pass-through |
| `currency` | STRING | `raw_revenue_transactions.currency` | Pass-through |
| `customer_id` | STRING | `raw_revenue_transactions.customer_id` | Pass-through |
| `product_line` | STRING | `raw_revenue_transactions.product_line` | Pass-through |
| `region` | STRING | `raw_revenue_transactions.region` | Pass-through |
| `metadata` | JSON | `raw_revenue_transactions.metadata` | Pass-through |
| `surrogate_key` | STRING | Derived | `dbt_utils.generate_surrogate_key(['transaction_id'])` |
| `ingestion_timestamp` | TIMESTAMP | `raw_revenue_transactions.ingestion_timestamp` | Pass-through |
| `source_system` | STRING | Constant | `'pubsub_ingestion'` |

**Tests:** `transaction_id` not_null; `surrogate_key` unique + not_null; `currency` accepted_values (USD, EUR, GBP, JPY); `product_line` accepted_values; `region` accepted_values.

#### stg_usage_metrics

| Column | Type | Source | Transformation |
|--------|------|--------|----------------|
| `metric_id` | STRING | `raw_usage_metrics.metric_id` | Pass-through |
| `event_timestamp` | TIMESTAMP | `raw_usage_metrics.timestamp` | `parse_event_timestamp` macro |
| `event_date` | DATE | Derived | `DATE(event_timestamp)` |
| `customer_id` | STRING | `raw_usage_metrics.customer_id` | Pass-through |
| `metric_type` | STRING | `raw_usage_metrics.metric_type` | Pass-through |
| `quantity` | FLOAT64 | `raw_usage_metrics.quantity` | Pass-through |
| `unit` | STRING | `raw_usage_metrics.unit` | Pass-through |
| `surrogate_key` | STRING | Derived | `dbt_utils.generate_surrogate_key(['metric_id'])` |
| `ingestion_timestamp` | TIMESTAMP | `raw_usage_metrics.ingestion_timestamp` | Pass-through |
| `source_system` | STRING | Constant | `'pubsub_ingestion'` |

**Tests:** `metric_id` not_null; `surrogate_key` unique + not_null; `metric_type` accepted_values (api_calls, tokens_processed, compute_hours); `customer_id` relationships to `stg_revenue_transactions.customer_id` (severity: warn).

#### stg_cost_records

| Column | Type | Source | Transformation |
|--------|------|--------|----------------|
| `record_id` | STRING | `raw_cost_records.record_id` | Pass-through |
| `event_timestamp` | TIMESTAMP | `raw_cost_records.timestamp` | `parse_event_timestamp` macro |
| `event_date` | DATE | Derived | `DATE(event_timestamp)` |
| `cost_center` | STRING | `raw_cost_records.cost_center` | Pass-through |
| `category` | STRING | `raw_cost_records.category` | Pass-through |
| `amount_cents` | INT64 | `raw_cost_records.amount_cents` | Pass-through |
| `currency` | STRING | `raw_cost_records.currency` | Pass-through |
| `vendor` | STRING | `raw_cost_records.vendor` | Pass-through |
| `description` | STRING | `raw_cost_records.description` | Pass-through |
| `surrogate_key` | STRING | Derived | `dbt_utils.generate_surrogate_key(['record_id'])` |
| `ingestion_timestamp` | TIMESTAMP | `raw_cost_records.ingestion_timestamp` | Pass-through |
| `source_system` | STRING | Constant | `'pubsub_ingestion'` |

**Tests:** `record_id` not_null; `surrogate_key` unique + not_null; `category` accepted_values (compute, storage, network, personnel); `cost_center` relationships to `cost_center_hierarchy.cost_center` (severity: warn).

### Intermediate Models

#### int_daily_revenue

Aggregates revenue transactions by date, product line, region, and currency. Joins with the `currency_exchange_rates` seed to convert all amounts to USD cents.

| Column | Type | Description |
|--------|------|-------------|
| `revenue_date` | DATE | Aggregation date |
| `product_line` | STRING | Product line |
| `region` | STRING | Geographic region |
| `currency` | STRING | Original currency |
| `transaction_count` | INT64 | Number of transactions |
| `total_amount_cents` | INT64 | Sum of `amount_cents` in original currency |
| `total_amount_cents_usd` | INT64 | Sum converted to USD cents |
| `avg_amount_cents_usd` | INT64 | Average transaction amount in USD cents |

#### int_customer_usage_aggregated

Aggregates usage by customer, day and metric type, with 7-day and 30-day rolling averages (`int_customer_usage_aggregated.sql`).

| Column | Type | Description |
|--------|------|-------------|
| `customer_id` | STRING | Customer identifier |
| `metric_date` | DATE | Usage date |
| `metric_type` | STRING | api_calls, tokens_processed or compute_hours |
| `total_quantity` | FLOAT64 | Sum of `quantity` for the day |
| `event_count` | INT64 | Number of events |
| `unit` | STRING | Unit of measurement |
| `rolling_7d_avg` / `rolling_30d_avg` | FLOAT64 | Rolling averages of `total_quantity` |
| `prev_day_quantity` | FLOAT64 | Previous day's `total_quantity` |

#### int_cost_by_center

Aggregates cost records by center, month, and category with joins to the cost center hierarchy seed.

| Column | Type | Description |
|--------|------|-------------|
| `cost_center` | STRING | Cost center identifier |
| `cost_month` | DATE | First day of month |
| `category` | STRING | Cost category |
| `currency` | STRING | Original currency |
| `total_cents` | INT64 | Sum of `amount_cents` |
| `record_count` | INT64 | Number of records |
| `department` | STRING | From cost_center_hierarchy seed |
| `division` | STRING | From cost_center_hierarchy seed |

### Mart Models

#### fct_daily_revenue_summary

Primary revenue reporting table. Partitioned by `revenue_date`, clustered by `product_line` and `region`.

| Column | Type | Description |
|--------|------|-------------|
| `revenue_date` | DATE | Calendar date |
| `product_line` | STRING | Product line |
| `region` | STRING | Geographic region |
| `transaction_count` | INT64 | Total transactions |
| `total_revenue_cents_usd` | INT64 | Total revenue in USD cents |
| `total_revenue_usd` | NUMERIC | Total revenue in USD (2 decimal places) |
| `avg_transaction_cents_usd` | INT64 | Average transaction in USD cents |
| `prev_day_revenue_usd` | NUMERIC | Previous day revenue (LAG window) |
| `dod_growth_rate` | NUMERIC | Day-over-day growth rate |
| `prev_week_revenue_usd` | NUMERIC | Revenue 7 days prior (LAG window) |
| `wow_growth_rate` | NUMERIC | Week-over-week growth rate |
| `mtd_revenue_usd` | NUMERIC | Month-to-date running total |

#### fct_monthly_cost_attribution

Monthly cost rollup with category-level breakdown and cost center hierarchy enrichment.

| Column | Type | Description |
|--------|------|-------------|
| `cost_center` | STRING | Cost center |
| `cost_month` | DATE | First day of month |
| `currency` | STRING | Original currency |
| `compute_cents` | INT64 | Compute category total |
| `storage_cents` | INT64 | Storage category total |
| `network_cents` | INT64 | Network category total |
| `personnel_cents` | INT64 | Personnel category total |
| `total_cents` | INT64 | Grand total in cents |
| `compute_usd` through `total_usd` | NUMERIC | USD conversions |
| `compute_pct` through `personnel_pct` | NUMERIC | Category percentage of total |
| `total_records` | INT64 | Number of source records |
| `budget_amount_usd` | NUMERIC | Budget placeholder (NULL) |
| `budget_variance_usd` | NUMERIC | Variance placeholder (NULL) |
| `budget_variance_pct` | NUMERIC | Variance % placeholder (NULL) |
| `department` | STRING | From cost center hierarchy |
| `division` | STRING | From cost center hierarchy |

#### fct_revenue_by_product_region

Cross-tabulation with pivoted region columns and running totals.

| Column | Type | Description |
|--------|------|-------------|
| `revenue_date` | DATE | Calendar date |
| `product_line` | STRING | Product line |
| `region` | STRING | Geographic region |
| `transaction_count` | INT64 | Transactions for this combination |
| `total_revenue_usd` | NUMERIC | Revenue for this combination |
| `us_east_revenue_usd` | NUMERIC | Pivoted: us-east revenue |
| `us_west_revenue_usd` | NUMERIC | Pivoted: us-west revenue |
| `eu_west_revenue_usd` | NUMERIC | Pivoted: eu-west revenue |
| `ap_southeast_revenue_usd` | NUMERIC | Pivoted: ap-southeast revenue |
| `product_total_revenue_usd` | NUMERIC | All regions for this product |
| `running_total_revenue_usd` | NUMERIC | Cumulative revenue |
| `running_total_transactions` | INT64 | Cumulative transactions |
| `product_display_name` | STRING | From product_line_mapping seed |
| `business_unit` | STRING | From product_line_mapping seed |

#### fct_customer_usage_report

Per-customer lifetime usage with tier classification.

| Column | Type | Description |
|--------|------|-------------|
| `customer_id` | STRING | Unique customer (PK) |
| `usage_tier` | STRING | `free` (<1K calls), `growth` (1K-100K), `enterprise` (>=100K) |
| `total_api_calls` | NUMERIC | Lifetime API calls |
| `total_tokens_processed` | NUMERIC | Lifetime tokens |
| `total_compute_hours` | NUMERIC | Lifetime compute hours |
| `first_seen_date` | DATE | Earliest activity |
| `last_seen_date` | DATE | Most recent activity |
| `account_age_days` | INT64 | Days between first and last seen |
| `active_days` | INT64 | Days with at least one API call |
| `avg_daily_api_calls` | NUMERIC | API calls per active day |
| `avg_tokens_per_call` | NUMERIC | Tokens per API call |
| `avg_daily_compute_hours` | NUMERIC | Compute hours per active day |

#### fct_unit_economics

Cross-model join of revenue, usage, and cost data for per-unit profitability analysis.

| Column | Type | Description |
|--------|------|-------------|
| `economics_month` | DATE | First day of month |
| `product_line` | STRING | Product line |
| `total_revenue_usd` | NUMERIC | Monthly revenue |
| `total_transactions` | INT64 | Monthly transaction count |
| `total_api_calls` | NUMERIC | Monthly API calls |
| `total_tokens_processed` | NUMERIC | Monthly tokens |
| `total_compute_hours` | NUMERIC | Monthly compute hours |
| `active_customers` | INT64 | Distinct customers with usage |
| `total_cost_usd` | NUMERIC | Monthly total cost |
| `revenue_per_api_call` | NUMERIC | Revenue / API calls |
| `revenue_per_token` | NUMERIC | Revenue / tokens |
| `revenue_per_compute_hour` | NUMERIC | Revenue / compute hours |
| `revenue_per_customer` | NUMERIC | Revenue / active customers |
| `cost_per_api_call` | NUMERIC | Cost / API calls |
| `cost_per_compute_hour` | NUMERIC | Cost / compute hours |
| `cost_per_customer` | NUMERIC | Cost / active customers |
| `gross_margin_usd` | NUMERIC | Revenue - Cost |
| `gross_margin_pct` | NUMERIC | Gross margin / Revenue |

---

## Seed Data

### currency_exchange_rates.csv

Provides exchange rates for converting non-USD amounts to USD in the intermediate layer.

### product_line_mapping.csv

Maps internal product line identifiers (`api_usage`, `enterprise_license`, `professional_services`) to display names and business units.

### cost_center_hierarchy.csv

Maps cost center identifiers to their department and division for organizational rollups in the cost attribution mart.

---

## Audit Schemas

The `access_log` and `permission_changes` entries below are the governance service's Pydantic models (`governance/app/models/audit.py`), kept in memory. The BigQuery tables of the same name in `fdp_<env>_audit` (`terraform/modules/bigquery`) use a different, more generic column set (`principal`, `resource`, `action`, `result`, ...) and nothing writes to them yet; aligning the two is a follow-up. `anomaly_alerts` is the one audit table that is written today, by the `AnomalyDetectionOperator`, and its schema is shared by the operator INSERT, Terraform and this document.

### access_log

Every access check (granted and denied) is logged to this append-only store.

| Field | Type | Description |
|-------|------|-------------|
| `log_id` | STRING (UUID) | Auto-generated unique identifier |
| `timestamp` | TIMESTAMP | When the check occurred |
| `user_id` | STRING | Who requested access |
| `dataset_id` | STRING | What they tried to access |
| `action` | STRING | `check` or `request` |
| `permission` | STRING | `read`, `write`, or `admin` |
| `result` | STRING | `granted` or `denied` |
| `role` | STRING | User's RBAC role at time of check |
| `ip_address` | STRING | Client IP address |
| `user_agent` | STRING | Client user agent string |
| `session_id` | STRING | Session identifier (if available) |
| `matched_pattern` | STRING | RBAC pattern that matched (NULL for denied) |

### permission_changes

Every grant and revoke operation.

| Field | Type | Description |
|-------|------|-------------|
| `log_id` | STRING (UUID) | Auto-generated unique identifier |
| `timestamp` | TIMESTAMP | When the change occurred |
| `admin_user_id` | STRING | Admin who made the change |
| `target_user_id` | STRING | User whose permissions changed |
| `dataset_id` | STRING | Affected dataset |
| `permission` | STRING | Permission granted or revoked |
| `action` | STRING | `grant` or `revoke` |
| `reason` | STRING | Justification for the change |

### pipeline_audit_log

Every Airflow DAG execution. The `update_audit_log` task builds this record and logs it; the BigQuery insert into `fdp_<env>_audit.pipeline_audit_log` (whose Terraform columns are `run_id`, `dag_id`, `task_id`, `started_at`, `finished_at`, `status`, `rows_affected`, `error_message`) is not implemented.

| Field | Type | Description |
|-------|------|-------------|
| `audit_id` | STRING (UUID) | Auto-generated unique identifier |
| `dag_id` | STRING | DAG identifier |
| `run_id` | STRING | Airflow run identifier |
| `start_time` | TIMESTAMP | When the DAG run started |
| `end_time` | TIMESTAMP | When the DAG run completed |
| `status` | STRING | Final DAG run state |
| `records_processed` | STRING (JSON) | Record counts per event type |
| `user` | STRING | Triggering user (typically `airflow-scheduler`) |

### anomaly_alerts

Statistical outliers in total daily revenue detected by `AnomalyDetectionOperator` (`orchestration/plugins/operators/anomaly_detection_operator.py`). One row per flagged `revenue_date`. This is the single definition shared by the operator's INSERT, `terraform/modules/bigquery` (`google_bigquery_table.anomaly_alerts`, partitioned by `detected_at`) and this document.

| Field | Type | Mode | Description |
|-------|------|------|-------------|
| `alert_id` | STRING (UUID) | REQUIRED | Generated per alert |
| `detected_at` | TIMESTAMP | REQUIRED | When the operator ran (partition column) |
| `revenue_date` | DATE | REQUIRED | The day whose revenue was flagged |
| `alert_type` | STRING | REQUIRED | `spike` (above rolling average) or `drop` (below) |
| `severity` | STRING | REQUIRED | `warning` (> threshold, default 2 sigma) or `critical` (> 3 sigma) |
| `source_table` | STRING | REQUIRED | Table analysed, e.g. `fdp_prod_marts_finance.fct_daily_revenue_summary` |
| `daily_revenue` | FLOAT64 | REQUIRED | Observed `SUM(total_revenue_usd)` for the day |
| `rolling_avg` | FLOAT64 | REQUIRED | Rolling mean over the lookback window (default 30 days) |
| `rolling_stddev` | FLOAT64 | REQUIRED | Rolling standard deviation over the same window |
| `deviation_sigma` | FLOAT64 | REQUIRED | `ABS(daily_revenue - rolling_avg) / rolling_stddev` |
| `dag_run_id` | STRING | NULLABLE | Airflow run that produced the alert |

---

## BigQuery Dataset Organization

Every dataset is named `fdp_<env>_<layer>` with `<env>` in `dev`, `staging`, `prod`. Terraform (`terraform/modules/bigquery`), dbt (`profiles.yml` dataset `fdp_<env>` + `+schema` per layer), the Airflow DAG (`BQ_DATASET_*` from Cloud Composer), the governance service (`fdp_<env>_audit`) and docker-compose all use the same names. RBAC patterns in the governance service use the logical `<layer>` (`marts_finance.*`).

| Dataset | Created by | Contains | Access |
|---------|-----------|----------|--------|
| `fdp_<env>_raw` | Terraform (tables) | Landing tables loaded by the DAG (`raw_*`) | Airflow SA (write), dbt SA (read) |
| `fdp_<env>_staging` | Terraform (dataset), dbt (views) | Deduplicated, typed `stg_*` views | Data Engineer (read/write) |
| `fdp_<env>_intermediate` | Terraform (dataset) | Empty: intermediate models are ephemeral | Data Engineer (read/write) |
| `fdp_<env>_marts_finance` | Terraform (dataset), dbt (tables) | Revenue, cost, product reporting | Finance Analyst, Executive (read) |
| `fdp_<env>_marts_analytics` | Terraform (dataset), dbt (tables) | Usage, unit economics | Finance Analyst, Data Engineer, Executive (read) |
| `fdp_<env>_seeds` | dbt | Exchange rates, product lines, cost centers | Data Engineer |
| `fdp_<env>_audit` | Terraform (tables) | Access logs, permission changes, pipeline audit, anomaly alerts | Auditor (read only) |
| `fdp_<env>_snapshots` | Terraform (disaster_recovery) | Daily table copies (`<table>_snapshot_<run_date>`) | Admin only |

---

## BigTable Schema

Written by `ingestion-service/internal/bigtable/writer.go` (`RowKey`, `WriteEvent`); `scripts/seed_bigtable.py` writes the identical layout.

| Component | Value |
|-----------|-------|
| **Instance** | `financial-events-<env>` (Terraform); `financial-events` locally (`BIGTABLE_INSTANCE_ID`) |
| **Table** | `financial_events` (Terraform); `events` locally (`BIGTABLE_TABLE_ID`, service default) |
| **Row Key** | `{event_type}#{reverse_ts}#{event_id}` where `reverse_ts = math.MaxInt64 - event_unix_ms`, formatted with at least 13 digits (19 in practice), e.g. `revenue_transaction#9223370299990775807#550e8400-e29b-41d4-a716-446655440000` |
| **`event_data`** | column `raw`: the validated JSON payload (90-day GC) |
| **`metadata`** | one column per Pub/Sub attribute: `event_type`, `event_id`, `timestamp` (1 version) |
| **`processing_status`** | `received_at`, `validated_at` RFC 3339 timestamps (3 versions) |

The event-type prefix makes "recent events of one type" a short prefix scan; the reverse timestamp puts the newest event first within that prefix; the event ID suffix keeps keys unique. Writes use a conditional mutation on `event_data:raw`, so a redelivered event is a no-op.
