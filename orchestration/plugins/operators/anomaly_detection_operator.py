"""Custom Airflow operator for statistical anomaly detection on financial data."""

import logging
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from airflow.models import BaseOperator
from airflow.utils.context import Context
from google.cloud import bigquery

logger = logging.getLogger(__name__)


class AnomalyDetectionOperator(BaseOperator):
    """Detect anomalies in daily revenue using rolling statistics.

    Flags any day where revenue deviates more than a configurable number of
    standard deviations from the rolling average. Writes flagged anomalies
    to the audit.anomaly_alerts BigQuery table.
    """

    template_fields = ("project_id", "source_table", "alert_table")

    def __init__(
        self,
        *,
        project_id: str,
        source_table: str = "marts_finance.fct_daily_revenue_summary",
        alert_table: str = "audit.anomaly_alerts",
        lookback_days: int = 30,
        std_dev_threshold: float = 2.0,
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self.project_id = project_id
        self.source_table = source_table
        self.alert_table = alert_table
        self.lookback_days = lookback_days
        self.std_dev_threshold = std_dev_threshold

    def _build_anomaly_query(self) -> str:
        """Build the BigQuery SQL that detects anomalies via rolling statistics."""
        window_size = self.lookback_days - 1  # ROWS BETWEEN N PRECEDING AND CURRENT ROW
        return f"""
            WITH daily AS (
                SELECT
                    revenue_date,
                    SUM(total_revenue_usd) AS daily_revenue
                FROM `{self.project_id}.{self.source_table}`
                WHERE revenue_date >= DATE_SUB(CURRENT_DATE(), INTERVAL {self.lookback_days * 2} DAY)
                GROUP BY 1
            ),
            with_stats AS (
                SELECT
                    revenue_date,
                    daily_revenue,
                    AVG(daily_revenue) OVER (
                        ORDER BY revenue_date
                        ROWS BETWEEN {window_size} PRECEDING AND CURRENT ROW
                    ) AS rolling_avg,
                    STDDEV(daily_revenue) OVER (
                        ORDER BY revenue_date
                        ROWS BETWEEN {window_size} PRECEDING AND CURRENT ROW
                    ) AS rolling_stddev
                FROM daily
            )
            SELECT
                revenue_date,
                daily_revenue,
                rolling_avg,
                rolling_stddev,
                SAFE_DIVIDE(
                    ABS(daily_revenue - rolling_avg),
                    rolling_stddev
                ) AS deviation_sigma,
                CASE
                    WHEN daily_revenue > rolling_avg THEN 'spike'
                    ELSE 'drop'
                END AS alert_type
            FROM with_stats
            WHERE rolling_stddev > 0
              AND ABS(daily_revenue - rolling_avg) > {self.std_dev_threshold} * rolling_stddev
            ORDER BY revenue_date DESC
        """

    def _build_insert_query(self, anomalies: list[dict[str, Any]], dag_run_id: str) -> str:
        """Build a BigQuery INSERT statement for the detected anomalies."""
        if not anomalies:
            return ""

        detected_at = datetime.now(tz=timezone.utc).isoformat()
        value_rows = []
        for anomaly in anomalies:
            alert_id = str(uuid4())
            value_rows.append(
                f"('{alert_id}', "
                f"DATE('{anomaly['revenue_date']}'), "
                f"{anomaly['daily_revenue']}, "
                f"{anomaly['rolling_avg']}, "
                f"{anomaly['rolling_stddev']}, "
                f"{anomaly['deviation_sigma']}, "
                f"'{anomaly['alert_type']}', "
                f"TIMESTAMP('{detected_at}'), "
                f"'{dag_run_id}')"
            )

        values_clause = ",\n                ".join(value_rows)
        return f"""
            INSERT INTO `{self.project_id}.{self.alert_table}` (
                alert_id,
                revenue_date,
                daily_revenue,
                rolling_avg,
                rolling_stddev,
                deviation_sigma,
                alert_type,
                detected_at,
                dag_run_id
            )
            VALUES
                {values_clause}
        """

    def execute(self, context: Context) -> dict[str, Any]:
        """Run anomaly detection and write alerts."""
        client = bigquery.Client(project=self.project_id)
        dag_run = context["dag_run"]
        dag_run_id = dag_run.run_id if dag_run else "manual"

        # Step 1: Query for anomalies using rolling window statistics
        anomaly_query = self._build_anomaly_query()
        logger.info(
            "Running anomaly detection on %s.%s (lookback=%d days, threshold=%.1f sigma)",
            self.project_id,
            self.source_table,
            self.lookback_days,
            self.std_dev_threshold,
        )

        query_job = client.query(anomaly_query)
        rows = list(query_job.result())

        anomalies: list[dict[str, Any]] = []
        anomaly_dates: list[str] = []
        for row in rows:
            anomaly = {
                "revenue_date": str(row["revenue_date"]),
                "daily_revenue": float(row["daily_revenue"]),
                "rolling_avg": float(row["rolling_avg"]),
                "rolling_stddev": float(row["rolling_stddev"]),
                "deviation_sigma": float(row["deviation_sigma"]),
                "alert_type": row["alert_type"],
            }
            anomalies.append(anomaly)
            anomaly_dates.append(str(row["revenue_date"]))

        num_anomalies = len(anomalies)
        logger.info("Detected %d anomalies in daily revenue", num_anomalies)

        # Step 2: Write anomalies to the alert table
        if anomalies:
            insert_query = self._build_insert_query(anomalies, dag_run_id)
            logger.info(
                "Writing %d anomaly alerts to %s.%s",
                num_anomalies,
                self.project_id,
                self.alert_table,
            )
            insert_job = client.query(insert_query)
            insert_job.result()  # Wait for completion
            logger.info("Anomaly alerts written successfully")

            for anomaly in anomalies:
                logger.warning(
                    "Anomaly detected: date=%s, revenue=%.2f, avg=%.2f, "
                    "stddev=%.2f, deviation=%.1f sigma, type=%s",
                    anomaly["revenue_date"],
                    anomaly["daily_revenue"],
                    anomaly["rolling_avg"],
                    anomaly["rolling_stddev"],
                    anomaly["deviation_sigma"],
                    anomaly["alert_type"],
                )
        else:
            logger.info("No anomalies detected — daily revenue within normal bounds")

        # Step 3: Return metadata for XCom
        return {
            "anomalies_detected": num_anomalies,
            "dates": anomaly_dates,
        }
