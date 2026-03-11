"""Tests for the financial_pipeline_daily DAG.

These tests verify DAG structure, not task execution. They catch
common Airflow footguns: import errors, cycles, missing dependencies,
and misconfigured operators.
"""

import pytest
from airflow.models import DagBag


@pytest.fixture(scope="module")
def dagbag():
    """Load all DAGs from the dags directory."""
    return DagBag(dag_folder="dags/", include_examples=False)


class TestFinancialPipelineDAG:
    DAG_ID = "financial_pipeline_daily"

    def test_dag_loaded(self, dagbag):
        """DAG file imports without errors."""
        assert dagbag.import_errors == {}, (
            f"DAG import errors: {dagbag.import_errors}"
        )

    def test_dag_exists(self, dagbag):
        assert self.DAG_ID in dagbag.dags

    def test_task_count(self, dagbag):
        dag = dagbag.dags[self.DAG_ID]
        assert len(dag.tasks) == 7

    def test_task_ids(self, dagbag):
        dag = dagbag.dags[self.DAG_ID]
        expected_tasks = {
            "check_source_freshness",
            "load_to_staging",
            "run_dbt_transformations",
            "run_dbt_tests",
            "generate_financial_reports",
            "run_anomaly_detection",
            "update_audit_log",
        }
        assert {t.task_id for t in dag.tasks} == expected_tasks

    def test_dependencies(self, dagbag):
        """Verify the task dependency graph matches the PRD specification."""
        dag = dagbag.dags[self.DAG_ID]

        # check_source_freshness >> load_to_staging
        assert "load_to_staging" in _downstream_ids(dag, "check_source_freshness")

        # load_to_staging >> run_dbt_transformations
        assert "run_dbt_transformations" in _downstream_ids(dag, "load_to_staging")

        # run_dbt_transformations >> run_dbt_tests
        assert "run_dbt_tests" in _downstream_ids(dag, "run_dbt_transformations")

        # run_dbt_tests >> [generate_financial_reports, run_anomaly_detection]
        downstream = _downstream_ids(dag, "run_dbt_tests")
        assert "generate_financial_reports" in downstream
        assert "run_anomaly_detection" in downstream

        # [generate_financial_reports, run_anomaly_detection] >> update_audit_log
        assert "update_audit_log" in _downstream_ids(
            dag, "generate_financial_reports"
        )
        assert "update_audit_log" in _downstream_ids(
            dag, "run_anomaly_detection"
        )

    def test_no_cycles(self, dagbag):
        dag = dagbag.dags[self.DAG_ID]
        # If the DAG has cycles Airflow raises during import, but be explicit.
        assert not dag.test_cycle()

    def test_default_args(self, dagbag):
        dag = dagbag.dags[self.DAG_ID]
        assert dag.default_args["retries"] == 3
        assert dag.default_args["retry_exponential_backoff"] is True

    def test_schedule(self, dagbag):
        dag = dagbag.dags[self.DAG_ID]
        # Airflow 2.x exposes schedule as schedule_interval (string or
        # timedelta) or via the timetable. Check the canonical attribute
        # first, then fall back.
        schedule = getattr(dag, "schedule_interval", None)
        if schedule is None:
            schedule = str(getattr(dag, "timetable", ""))
        assert "0 2 * * *" in str(schedule)

    def test_max_active_runs(self, dagbag):
        dag = dagbag.dags[self.DAG_ID]
        assert dag.max_active_runs == 1

    def test_tags(self, dagbag):
        dag = dagbag.dags[self.DAG_ID]
        assert "financial" in dag.tags
        assert "production" in dag.tags

    def test_audit_log_trigger_rule(self, dagbag):
        """Audit log should run even if upstream tasks fail."""
        dag = dagbag.dags[self.DAG_ID]
        audit_task = dag.get_task("update_audit_log")
        assert str(audit_task.trigger_rule) == "all_done"


def _downstream_ids(dag, task_id: str) -> set[str]:
    """Return the set of direct downstream task IDs for a given task."""
    task = dag.get_task(task_id)
    return {t.task_id for t in task.downstream_list}
