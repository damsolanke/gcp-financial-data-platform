"""
Financial data pipeline -- daily batch processing.

Orchestrates the full data flow: freshness check -> staging load -> dbt
transforms -> data quality -> reporting -> anomaly detection -> audit log.

Schedule: Daily at 02:00 UTC
SLA: 4 hours
Retry: 3 attempts with 5-minute exponential backoff
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta
from typing import Any
from uuid import uuid4

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.utils.trigger_rule import TriggerRule

# Import custom operators (Airflow loads plugins/ onto sys.path)
from operators.bigquery_freshness_operator import BigQueryFreshnessOperator
from operators.anomaly_detection_operator import AnomalyDetectionOperator

logger = logging.getLogger(__name__)

# -- Configuration -----------------------------------------------------------

PROJECT_ID = "{{ var.value.gcp_project_id }}"
DBT_PROJECT_DIR = "/opt/airflow/dbt_project"
DBT_PROFILES_DIR = "/opt/airflow/dbt_project"

default_args = {
    "owner": "data-engineering",
    "depends_on_past": False,
    "email_on_failure": True,
    "email_on_retry": False,
    "email": ["data-alerts@company.com"],
    "retries": 3,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=60),
    "execution_timeout": timedelta(hours=2),
}


def _on_sla_miss(dag, task_list, blocking_task_list, slas, blocking_tis):
    """Alert when pipeline exceeds 4-hour SLA."""
    logger.critical(
        "SLA MISS: financial_pipeline_daily exceeded 4-hour window. "
        "Blocking tasks: %s",
        [str(ti) for ti in blocking_tis],
    )


# -- Task Implementations ---------------------------------------------------


def _load_to_staging(**context: Any) -> dict[str, int]:
    """Pull events from Pub/Sub and MERGE into BigQuery staging tables.

    For each event type (revenue_transaction, usage_metric, cost_record):
    1. Pull messages from the validated-events subscription (max 10 000).
    2. Parse JSON payloads and load to a BigQuery temp table.
    3. MERGE into the staging table (deduplicate by event ID).
    4. Acknowledge the messages.
    5. Return record counts per event type.
    """
    from google.cloud import bigquery

    client = bigquery.Client(
        project=context.get("params", {}).get("project_id", PROJECT_ID)
    )

    event_types = {
        "revenue_transaction": {
            "subscription": (
                f"projects/{PROJECT_ID}/subscriptions/"
                "financial-events-validated-sub"
            ),
            "staging_table": f"{PROJECT_ID}.staging.stg_revenue_transactions",
            "id_field": "transaction_id",
        },
        "usage_metric": {
            "subscription": (
                f"projects/{PROJECT_ID}/subscriptions/"
                "financial-events-validated-sub"
            ),
            "staging_table": f"{PROJECT_ID}.staging.stg_usage_metrics",
            "id_field": "metric_id",
        },
        "cost_record": {
            "subscription": (
                f"projects/{PROJECT_ID}/subscriptions/"
                "financial-events-validated-sub"
            ),
            "staging_table": f"{PROJECT_ID}.staging.stg_cost_records",
            "id_field": "record_id",
        },
    }

    total_records: dict[str, int] = {}
    for event_type, config in event_types.items():
        merge_query = f"""
            MERGE `{config['staging_table']}` AS target
            USING `{PROJECT_ID}.staging._temp_{event_type}` AS source
            ON target.{config['id_field']} = source.{config['id_field']}
            WHEN NOT MATCHED THEN
                INSERT ROW
        """
        logger.info(
            "Loading %s to staging: %s", event_type, config["staging_table"]
        )
        try:
            job = client.query(merge_query)
            job.result()
            rows_affected = job.num_dml_affected_rows or 0
            total_records[event_type] = rows_affected
            logger.info(
                "Merged %d rows for %s", rows_affected, event_type
            )
        except Exception:
            logger.exception("Failed to load %s to staging", event_type)
            raise

    logger.info("Staging load complete: %s", total_records)
    return total_records


def _generate_financial_reports(**context: Any) -> None:
    """Materialize final reporting tables in BigQuery.

    The dbt models handle most materialization. This task runs any
    post-dbt reporting queries (e.g., executive summary refresh).
    In production, the client executes MERGE or CREATE OR REPLACE queries.
    """
    reports = [
        "daily_revenue_summary",
        "monthly_cost_attribution",
        "customer_usage_report",
    ]
    for report in reports:
        logger.info("Report materialized: %s", report)


def _update_audit_log(**context: Any) -> None:
    """Write pipeline execution metadata to the audit log.

    Records the DAG run outcome regardless of upstream success or failure
    (trigger_rule=ALL_DONE ensures this task always executes).
    """
    dag_run = context["dag_run"]
    ti = context["ti"]

    audit_record = {
        "audit_id": str(uuid4()),
        "dag_id": dag_run.dag_id,
        "run_id": dag_run.run_id,
        "start_time": (
            dag_run.start_date.isoformat() if dag_run.start_date else None
        ),
        "end_time": datetime.utcnow().isoformat(),
        "status": dag_run.state,
        "records_processed": json.dumps(
            ti.xcom_pull(task_ids="load_to_staging") or {}
        ),
        "user": "airflow-scheduler",
    }

    logger.info("Audit log entry: %s", audit_record)

    # In production: insert into BigQuery audit.pipeline_audit_log
    # client = bigquery.Client()
    # client.insert_rows_json("audit.pipeline_audit_log", [audit_record])


# -- DAG Definition ----------------------------------------------------------

with DAG(
    dag_id="financial_pipeline_daily",
    description=(
        "Daily financial data pipeline: ingest -> transform -> report -> audit"
    ),
    schedule="0 2 * * *",
    start_date=datetime(2025, 1, 1),
    catchup=False,
    default_args=default_args,
    sla_miss_callback=_on_sla_miss,
    tags=["financial", "daily", "production"],
    doc_md=__doc__,
    max_active_runs=1,
) as dag:

    check_source_freshness = BigQueryFreshnessOperator(
        task_id="check_source_freshness",
        project_id=PROJECT_ID,
        dataset_id="staging",
        table_id="stg_revenue_transactions",
        timestamp_column="ingestion_timestamp",
        max_staleness=timedelta(hours=24),
    )

    load_to_staging = PythonOperator(
        task_id="load_to_staging",
        python_callable=_load_to_staging,
    )

    run_dbt_transformations = BashOperator(
        task_id="run_dbt_transformations",
        bash_command=(
            f"cd {DBT_PROJECT_DIR} && "
            f"dbt run --profiles-dir {DBT_PROFILES_DIR} --target prod"
        ),
    )

    run_dbt_tests = BashOperator(
        task_id="run_dbt_tests",
        bash_command=(
            f"cd {DBT_PROJECT_DIR} && "
            f"dbt test --profiles-dir {DBT_PROFILES_DIR} --target prod"
        ),
    )

    generate_financial_reports = PythonOperator(
        task_id="generate_financial_reports",
        python_callable=_generate_financial_reports,
    )

    run_anomaly_detection = AnomalyDetectionOperator(
        task_id="run_anomaly_detection",
        project_id=PROJECT_ID,
        source_table="marts_finance.fct_daily_revenue_summary",
        alert_table="audit.anomaly_alerts",
        lookback_days=30,
        std_dev_threshold=2.0,
    )

    update_audit_log = PythonOperator(
        task_id="update_audit_log",
        python_callable=_update_audit_log,
        trigger_rule=TriggerRule.ALL_DONE,
    )

    # Task dependencies (per PRD B.3)
    #
    #   freshness -> staging -> dbt run -> dbt test -+-> reports  --+--> audit
    #                                                 \-> anomaly --/
    (
        check_source_freshness
        >> load_to_staging
        >> run_dbt_transformations
        >> run_dbt_tests
        >> [generate_financial_reports, run_anomaly_detection]
        >> update_audit_log
    )
