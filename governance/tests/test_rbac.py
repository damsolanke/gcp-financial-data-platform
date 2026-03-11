"""Comprehensive RBAC tests.

Tests the permission matrix exhaustively to ensure:
- Every role can access what it should
- Every role is denied what it shouldn't access
- Glob-style pattern matching works correctly
- Permission escalation is prevented
"""

import pytest
from app.models.rbac import Role, Permission, AccessDecision
from app.services.access_control import check_access


# ---------------------------------------------------------------------------
# Admin: full access to everything
# ---------------------------------------------------------------------------
class TestAdminAccess:
    """Admin role should have read, write, and admin on all datasets."""

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "staging.stg_revenue_transactions",
            "intermediate.int_daily_balances",
            "marts_finance.dim_accounts",
            "marts_analytics.fct_daily_revenue",
            "audit.access_log",
            "some_unknown_dataset.table",
        ],
    )
    @pytest.mark.parametrize(
        "permission",
        [Permission.READ, Permission.WRITE, Permission.ADMIN],
    )
    def test_admin_access_granted(self, dataset_id: str, permission: Permission) -> None:
        """Admin should be granted any permission on any dataset."""
        result = check_access(Role.ADMIN, dataset_id, permission, user_id="admin-001")
        assert result.decision == AccessDecision.GRANTED
        assert result.matched_pattern == "*"
        assert result.role == Role.ADMIN


# ---------------------------------------------------------------------------
# Finance Analyst: read-only on marts_finance.* and marts_analytics.*
# ---------------------------------------------------------------------------
class TestFinanceAnalystAccess:
    """Finance analyst should only read from finance and analytics marts."""

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "marts_finance.dim_accounts",
            "marts_finance.fct_journal_entries",
            "marts_analytics.fct_daily_revenue",
            "marts_analytics.dim_cost_centers",
        ],
    )
    def test_analyst_read_granted(self, dataset_id: str) -> None:
        """Analyst can read from marts_finance and marts_analytics."""
        result = check_access(Role.FINANCE_ANALYST, dataset_id, Permission.READ, user_id="analyst-001")
        assert result.decision == AccessDecision.GRANTED
        assert result.matched_pattern is not None

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "staging.stg_revenue_transactions",
            "intermediate.int_daily_balances",
            "audit.access_log",
        ],
    )
    def test_analyst_read_denied_other_datasets(self, dataset_id: str) -> None:
        """Analyst cannot read from staging, intermediate, or audit datasets."""
        result = check_access(Role.FINANCE_ANALYST, dataset_id, Permission.READ, user_id="analyst-001")
        assert result.decision == AccessDecision.DENIED
        assert result.matched_pattern is None

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "marts_finance.dim_accounts",
            "marts_analytics.fct_daily_revenue",
        ],
    )
    @pytest.mark.parametrize(
        "permission",
        [Permission.WRITE, Permission.ADMIN],
    )
    def test_analyst_write_admin_denied(self, dataset_id: str, permission: Permission) -> None:
        """Analyst cannot write to or administer any dataset (read-only role)."""
        result = check_access(Role.FINANCE_ANALYST, dataset_id, permission, user_id="analyst-001")
        assert result.decision == AccessDecision.DENIED


# ---------------------------------------------------------------------------
# Data Engineer: read/write on staging.* and intermediate.*, read on marts_analytics.*
# ---------------------------------------------------------------------------
class TestDataEngineerAccess:
    """Data engineer has read/write on staging and intermediate, read on analytics."""

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "staging.stg_revenue_transactions",
            "staging.stg_account_balances",
            "intermediate.int_daily_balances",
            "intermediate.int_monthly_revenue",
        ],
    )
    @pytest.mark.parametrize(
        "permission",
        [Permission.READ, Permission.WRITE],
    )
    def test_engineer_staging_intermediate_rw(self, dataset_id: str, permission: Permission) -> None:
        """Engineer can read and write staging and intermediate datasets."""
        result = check_access(Role.DATA_ENGINEER, dataset_id, permission, user_id="engineer-001")
        assert result.decision == AccessDecision.GRANTED

    def test_engineer_analytics_read(self) -> None:
        """Engineer can read from marts_analytics."""
        result = check_access(
            Role.DATA_ENGINEER,
            "marts_analytics.fct_daily_revenue",
            Permission.READ,
            user_id="engineer-001",
        )
        assert result.decision == AccessDecision.GRANTED

    def test_engineer_analytics_write_denied(self) -> None:
        """Engineer cannot write to marts_analytics."""
        result = check_access(
            Role.DATA_ENGINEER,
            "marts_analytics.fct_daily_revenue",
            Permission.WRITE,
            user_id="engineer-001",
        )
        assert result.decision == AccessDecision.DENIED

    def test_engineer_finance_denied(self) -> None:
        """Engineer cannot access marts_finance at all."""
        result = check_access(
            Role.DATA_ENGINEER,
            "marts_finance.dim_accounts",
            Permission.READ,
            user_id="engineer-001",
        )
        assert result.decision == AccessDecision.DENIED

    def test_engineer_audit_denied(self) -> None:
        """Engineer cannot access audit datasets."""
        result = check_access(
            Role.DATA_ENGINEER,
            "audit.access_log",
            Permission.READ,
            user_id="engineer-001",
        )
        assert result.decision == AccessDecision.DENIED

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "staging.stg_revenue_transactions",
            "intermediate.int_daily_balances",
        ],
    )
    def test_engineer_admin_denied(self, dataset_id: str) -> None:
        """Engineer cannot administer datasets even in staging/intermediate."""
        result = check_access(Role.DATA_ENGINEER, dataset_id, Permission.ADMIN, user_id="engineer-001")
        assert result.decision == AccessDecision.DENIED


# ---------------------------------------------------------------------------
# Executive: read-only on marts
# ---------------------------------------------------------------------------
class TestExecutiveAccess:
    """Executive has read-only access to finance and analytics marts."""

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "marts_finance.dim_accounts",
            "marts_finance.fct_journal_entries",
            "marts_analytics.fct_daily_revenue",
        ],
    )
    def test_executive_read_granted(self, dataset_id: str) -> None:
        """Executive can read marts."""
        result = check_access(Role.EXECUTIVE, dataset_id, Permission.READ, user_id="exec-001")
        assert result.decision == AccessDecision.GRANTED

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "staging.stg_revenue_transactions",
            "intermediate.int_daily_balances",
            "audit.access_log",
        ],
    )
    def test_executive_other_datasets_denied(self, dataset_id: str) -> None:
        """Executive cannot read staging, intermediate, or audit."""
        result = check_access(Role.EXECUTIVE, dataset_id, Permission.READ, user_id="exec-001")
        assert result.decision == AccessDecision.DENIED

    @pytest.mark.parametrize(
        "permission",
        [Permission.WRITE, Permission.ADMIN],
    )
    def test_executive_write_admin_denied(self, permission: Permission) -> None:
        """Executive cannot write to or administer any dataset."""
        result = check_access(
            Role.EXECUTIVE,
            "marts_finance.dim_accounts",
            permission,
            user_id="exec-001",
        )
        assert result.decision == AccessDecision.DENIED


# ---------------------------------------------------------------------------
# Auditor: read-only on audit.*
# ---------------------------------------------------------------------------
class TestAuditorAccess:
    """Auditor can only read audit datasets."""

    def test_auditor_audit_read_granted(self) -> None:
        """Auditor can read audit datasets."""
        result = check_access(Role.AUDITOR, "audit.access_log", Permission.READ, user_id="auditor-001")
        assert result.decision == AccessDecision.GRANTED
        assert result.matched_pattern == "audit.*"

    @pytest.mark.parametrize(
        "dataset_id",
        [
            "staging.stg_revenue_transactions",
            "intermediate.int_daily_balances",
            "marts_finance.dim_accounts",
            "marts_analytics.fct_daily_revenue",
        ],
    )
    def test_auditor_other_datasets_denied(self, dataset_id: str) -> None:
        """Auditor cannot read non-audit datasets."""
        result = check_access(Role.AUDITOR, dataset_id, Permission.READ, user_id="auditor-001")
        assert result.decision == AccessDecision.DENIED

    @pytest.mark.parametrize(
        "permission",
        [Permission.WRITE, Permission.ADMIN],
    )
    def test_auditor_write_admin_denied(self, permission: Permission) -> None:
        """Auditor cannot write to or administer audit datasets."""
        result = check_access(Role.AUDITOR, "audit.access_log", permission, user_id="auditor-001")
        assert result.decision == AccessDecision.DENIED


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------
class TestEdgeCases:
    """Edge cases and boundary conditions."""

    def test_unknown_dataset_denied(self) -> None:
        """Access to a completely unknown dataset is denied for non-admin roles."""
        result = check_access(
            Role.FINANCE_ANALYST,
            "nonexistent.table_xyz",
            Permission.READ,
            user_id="analyst-001",
        )
        assert result.decision == AccessDecision.DENIED

    def test_empty_dataset_denied(self) -> None:
        """Empty dataset string is denied for non-admin roles."""
        result = check_access(Role.FINANCE_ANALYST, "", Permission.READ, user_id="analyst-001")
        assert result.decision == AccessDecision.DENIED

    def test_permission_escalation_denied(self) -> None:
        """A read-only role cannot escalate to write."""
        result = check_access(
            Role.FINANCE_ANALYST,
            "marts_finance.dim_accounts",
            Permission.WRITE,
            user_id="analyst-001",
        )
        assert result.decision == AccessDecision.DENIED

    def test_result_contains_user_id(self) -> None:
        """The result object correctly contains the user_id."""
        result = check_access(
            Role.ADMIN, "staging.test", Permission.READ, user_id="admin-001"
        )
        assert result.user_id == "admin-001"

    def test_result_contains_dataset_id(self) -> None:
        """The result object correctly contains the dataset_id."""
        result = check_access(
            Role.ADMIN, "staging.test", Permission.READ, user_id="admin-001"
        )
        assert result.dataset_id == "staging.test"

    def test_result_contains_permission(self) -> None:
        """The result object correctly contains the requested permission."""
        result = check_access(
            Role.ADMIN, "staging.test", Permission.WRITE, user_id="admin-001"
        )
        assert result.permission == Permission.WRITE

    def test_denied_result_has_no_matched_pattern(self) -> None:
        """When access is denied, matched_pattern should be None."""
        result = check_access(
            Role.AUDITOR, "staging.test", Permission.READ, user_id="auditor-001"
        )
        assert result.decision == AccessDecision.DENIED
        assert result.matched_pattern is None

    def test_granted_result_has_matched_pattern(self) -> None:
        """When access is granted, matched_pattern should be set."""
        result = check_access(
            Role.AUDITOR, "audit.access_log", Permission.READ, user_id="auditor-001"
        )
        assert result.decision == AccessDecision.GRANTED
        assert result.matched_pattern is not None

    def test_glob_pattern_specificity(self) -> None:
        """Verify that staging.* matches staging.anything but not stagingX.anything."""
        granted = check_access(
            Role.DATA_ENGINEER, "staging.test_table", Permission.READ, user_id="eng-001"
        )
        assert granted.decision == AccessDecision.GRANTED

        # 'stagingX.test_table' should NOT match 'staging.*'
        denied = check_access(
            Role.DATA_ENGINEER, "stagingX.test_table", Permission.READ, user_id="eng-001"
        )
        assert denied.decision == AccessDecision.DENIED
