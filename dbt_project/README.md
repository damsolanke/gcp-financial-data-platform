# Financial Data Platform - dbt Project

dbt transformation layer for the GCP Financial Data Infrastructure Platform. Transforms raw financial event data (revenue transactions, usage metrics, cost records) ingested via Pub/Sub into analytics-ready mart tables in BigQuery.

## Model Lineage

```
Sources (fdp_<env>_raw landing tables)
  └── Staging (views: dedup, type casting, surrogate keys)
        ├── stg_revenue_transactions
        ├── stg_usage_metrics
        └── stg_cost_records
              └── Intermediate (ephemeral: aggregation, currency conversion, rolling calcs)
                    ├── int_daily_revenue
                    ├── int_customer_usage_aggregated
                    └── int_cost_by_center
                          └── Marts (tables: partitioned & clustered for query performance)
                                ├── Finance
                                │     ├── fct_daily_revenue_summary
                                │     ├── fct_monthly_cost_attribution
                                │     └── fct_revenue_by_product_region
                                └── Analytics
                                      ├── fct_customer_usage_report
                                      └── fct_unit_economics
```

## Environment Setup

Set the following environment variables before running:

```bash
export GCP_PROJECT_ID="your-gcp-project-id"
export BQ_DATASET="fdp_dev"                # fdp_<env> prefix; dbt appends _staging, _marts_finance, ...
export BQ_DATASET_RAW="fdp_dev_raw"        # landing tables written by the Airflow DAG (default: ${BQ_DATASET}_raw)
export GCP_KEYFILE_PATH="/path/to/service-account-key.json"
```

Every dataset follows `fdp_<env>_<layer>`, the same scheme Terraform provisions
(`terraform/modules/bigquery`): `fdp_<env>_raw` (sources), `fdp_<env>_staging`
(views), `fdp_<env>_marts_finance` / `fdp_<env>_marts_analytics` (tables) and
`fdp_<env>_seeds`. Intermediate models are ephemeral and have no dataset.

## Running

```bash
# Install dependencies
dbt deps

# Load seed data (exchange rates, product mappings, cost center hierarchy)
dbt seed

# Run all models
dbt run

# Run tests (schema + custom data quality assertions)
dbt test

# Generate and serve documentation
dbt docs generate
dbt docs serve
```

## Testing

- **Schema tests**: not_null, unique, accepted_values, and relationships defined in `schema.yml` files.
- **Custom data tests** in `tests/`:
  - `assert_revenue_non_negative` -- no negative revenue in daily summary.
  - `assert_no_orphan_transactions` -- all revenue customers have usage records.
  - `assert_date_completeness` -- no date gaps in the revenue date spine.

## Seeds

- `currency_exchange_rates.csv` -- static FX rates for USD conversion.
- `product_line_mapping.csv` -- product line display names and business units.
- `cost_center_hierarchy.csv` -- cost center to department/division mapping.
