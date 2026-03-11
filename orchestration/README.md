# Orchestration -- Airflow DAGs and Custom Operators

This module contains the Apache Airflow DAGs and custom operators that
orchestrate the GCP Financial Data Platform's daily batch processing.

## DAG: `financial_pipeline_daily`

Runs daily at **02:00 UTC** with a 4-hour SLA. The pipeline executes the
following task graph:

```
check_source_freshness
        |
  load_to_staging
        |
run_dbt_transformations
        |
   run_dbt_tests
      /     \
reports   anomaly_detection
      \     /
  update_audit_log
```

### Tasks

| Task ID | Type | Purpose |
|---|---|---|
| `check_source_freshness` | BigQueryFreshnessOperator | Skip the run if staging data is stale (> 24 h) |
| `load_to_staging` | PythonOperator | MERGE Pub/Sub events into BigQuery staging tables |
| `run_dbt_transformations` | BashOperator | `dbt run` against the production target |
| `run_dbt_tests` | BashOperator | `dbt test` for data quality validation |
| `generate_financial_reports` | PythonOperator | Materialize executive reporting views |
| `run_anomaly_detection` | AnomalyDetectionOperator | Flag revenue anomalies using rolling z-scores |
| `update_audit_log` | PythonOperator | Write run metadata to `audit.pipeline_audit_log` (runs on ALL_DONE) |

### Retry policy

- 3 retries with exponential backoff starting at 5 minutes (capped at 60 minutes).
- Per-task execution timeout: 2 hours.
- `update_audit_log` always runs (`trigger_rule=ALL_DONE`) to capture failures.

## Custom Operators

### `BigQueryFreshnessOperator`

Located in `plugins/operators/bigquery_freshness_operator.py`.

Queries `MAX(timestamp_column)` from a BigQuery table and raises
`AirflowSkipException` if the data is older than `max_staleness`. This
causes downstream tasks to be skipped rather than failed -- stale data means
there is nothing new to process, not that something is broken.

### `AnomalyDetectionOperator`

Located in `plugins/operators/anomaly_detection_operator.py`.

Computes rolling mean and standard deviation of daily revenue over a
configurable lookback window. Flags any day where revenue deviates beyond a
threshold (default: 2 sigma) and writes alerts to `audit.anomaly_alerts`.

## Directory Layout

```
orchestration/
  dags/
    financial_pipeline_daily.py   # Main DAG definition
  plugins/
    __init__.py
    operators/
      __init__.py
      bigquery_freshness_operator.py
      anomaly_detection_operator.py
  tests/
    __init__.py
    test_financial_pipeline.py    # DAG structure tests
  README.md
```

## Running Tests Locally

```bash
# From the orchestration/ directory
export AIRFLOW_HOME=$(pwd)
pip install apache-airflow pytest google-cloud-bigquery

# Ensure Airflow can find the plugins
export PYTHONPATH="${PYTHONPATH}:$(pwd)/plugins"

pytest tests/ -v
```

The tests validate DAG structure (import, task count, dependencies, schedule,
trigger rules) without executing any tasks or connecting to GCP.
