"""Guards the single anomaly_alerts schema.

The AnomalyDetectionOperator INSERT, the Terraform table definition in
terraform/modules/bigquery/main.tf and the table documented in
docs/data_model.md must list the same columns in the same order.
"""

import re
from pathlib import Path

import airflow  # noqa: F401  (puts the plugins folder on sys.path)
from operators.anomaly_detection_operator import (
    ANOMALY_ALERT_COLUMNS,
    AnomalyDetectionOperator,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


def _terraform_columns() -> list[str]:
    tf = (REPO_ROOT / "terraform/modules/bigquery/main.tf").read_text()
    block = tf.split('resource "google_bigquery_table" "anomaly_alerts"')[1]
    block = block.split("\nresource ")[0]
    return re.findall(r'\{ name = "(\w+)"', block)


def _documented_columns() -> list[str]:
    md = (REPO_ROOT / "docs/data_model.md").read_text()
    section = md.split("### anomaly_alerts")[1].split("\n---")[0]
    return re.findall(r"^\| `(\w+)` \|", section, flags=re.MULTILINE)


def _operator() -> AnomalyDetectionOperator:
    return AnomalyDetectionOperator(
        task_id="anomaly_schema_test",
        project_id="test-project",
        source_table="fdp_dev_marts_finance.fct_daily_revenue_summary",
        alert_table="fdp_dev_audit.anomaly_alerts",
    )


def test_terraform_columns_match_operator() -> None:
    assert _terraform_columns() == list(ANOMALY_ALERT_COLUMNS)


def test_documented_columns_match_operator() -> None:
    assert _documented_columns() == list(ANOMALY_ALERT_COLUMNS)


def test_insert_query_lists_every_column_in_order() -> None:
    op = _operator()
    query = op._build_insert_query(
        [
            {
                "revenue_date": "2025-01-15",
                "daily_revenue": 100.0,
                "rolling_avg": 50.0,
                "rolling_stddev": 10.0,
                "deviation_sigma": 5.0,
                "alert_type": "spike",
            },
            {
                "revenue_date": "2025-01-16",
                "daily_revenue": 30.0,
                "rolling_avg": 50.0,
                "rolling_stddev": 10.0,
                "deviation_sigma": 2.0,
                "alert_type": "drop",
            },
        ],
        dag_run_id="manual__2025-01-17",
    )
    columns_clause = query.split("(", 1)[1].split(")", 1)[0]
    listed = [c.strip() for c in columns_clause.split(",")]
    assert listed == list(ANOMALY_ALERT_COLUMNS)
    assert "`test-project.fdp_dev_audit.anomaly_alerts`" in query
    assert "'fdp_dev_marts_finance.fct_daily_revenue_summary'" in query
    # 5 sigma is critical, 2 sigma is a warning
    assert "'spike', 'critical'" in query
    assert "'drop', 'warning'" in query
    assert query.count("VALUES") == 1 and query.count("DATE('2025-01-") == 2


def test_no_anomalies_produces_no_query() -> None:
    assert _operator()._build_insert_query([], "run") == ""
