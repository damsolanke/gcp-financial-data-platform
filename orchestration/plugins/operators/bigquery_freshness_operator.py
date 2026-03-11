"""Custom Airflow operator to check BigQuery source data freshness."""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from airflow.exceptions import AirflowSkipException
from airflow.models import BaseOperator
from airflow.utils.context import Context
from google.cloud import bigquery

logger = logging.getLogger(__name__)


class BigQueryFreshnessOperator(BaseOperator):
    """Check that source data has been updated within a configurable threshold.

    Raises AirflowSkipException if data is stale (not AirflowException --
    stale data means "nothing new to process", not "something is broken").
    """

    template_fields = ("project_id", "dataset_id", "table_id", "timestamp_column")

    def __init__(
        self,
        *,
        project_id: str,
        dataset_id: str,
        table_id: str,
        timestamp_column: str = "ingestion_timestamp",
        max_staleness: timedelta = timedelta(hours=24),
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self.project_id = project_id
        self.dataset_id = dataset_id
        self.table_id = table_id
        self.timestamp_column = timestamp_column
        self.max_staleness = max_staleness

    def execute(self, context: Context) -> dict[str, Any]:
        """Query for the most recent record and compare against threshold."""
        client = bigquery.Client(project=self.project_id)

        fully_qualified_table = (
            f"`{self.project_id}.{self.dataset_id}.{self.table_id}`"
        )
        query = f"""
            SELECT MAX({self.timestamp_column}) AS most_recent
            FROM {fully_qualified_table}
        """

        logger.info(
            "Checking freshness of %s.%s.%s (column: %s, max_staleness: %s)",
            self.project_id,
            self.dataset_id,
            self.table_id,
            self.timestamp_column,
            self.max_staleness,
        )

        query_job = client.query(query)
        results = list(query_job.result())

        if not results or results[0]["most_recent"] is None:
            logger.warning(
                "No data found in %s.%s — skipping downstream tasks.",
                self.dataset_id,
                self.table_id,
            )
            raise AirflowSkipException(
                f"No data found in {self.dataset_id}.{self.table_id}. "
                "Nothing to process."
            )

        most_recent: datetime = results[0]["most_recent"]
        # Ensure timezone-aware comparison
        if most_recent.tzinfo is None:
            most_recent = most_recent.replace(tzinfo=timezone.utc)

        now = datetime.now(tz=timezone.utc)
        staleness = now - most_recent
        staleness_seconds = int(staleness.total_seconds())

        logger.info(
            "Freshness check for %s.%s: most_recent=%s, staleness=%s (threshold=%s)",
            self.dataset_id,
            self.table_id,
            most_recent.isoformat(),
            staleness,
            self.max_staleness,
        )

        if staleness > self.max_staleness:
            logger.warning(
                "Data in %s.%s is stale (%s > %s) — skipping downstream tasks.",
                self.dataset_id,
                self.table_id,
                staleness,
                self.max_staleness,
            )
            raise AirflowSkipException(
                f"Data in {self.dataset_id}.{self.table_id} is stale: "
                f"last update was {staleness} ago (threshold: {self.max_staleness})."
            )

        metadata = {
            "table": self.table_id,
            "most_recent": most_recent.isoformat(),
            "staleness_seconds": staleness_seconds,
        }
        logger.info("Freshness check passed: %s", metadata)
        return metadata
