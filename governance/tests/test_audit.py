"""Audit logging tests.

Verifies that all access checks and permission changes are properly logged
for compliance purposes. Every access decision (granted and denied) must
produce an audit trail entry.
"""

from fastapi.testclient import TestClient
from app.services.audit_logger import (
    get_access_logs,
    get_permission_changes,
)


class TestAccessCheckAuditLogging:
    """Verify that access checks create audit log entries."""

    def test_granted_access_creates_log_entry(self, client: TestClient) -> None:
        """A granted access check should produce an audit log entry."""
        response = client.get("/api/v1/access/check/admin-001/staging.test_table")
        assert response.status_code == 200

        logs = get_access_logs()
        assert len(logs) == 1
        assert logs[0].user_id == "admin-001"
        assert logs[0].dataset_id == "staging.test_table"
        assert logs[0].result == "granted"
        assert logs[0].action == "check"

    def test_denied_access_creates_log_entry(self, client: TestClient) -> None:
        """A denied access check should also produce an audit log entry."""
        response = client.get("/api/v1/access/check/auditor-001/staging.test_table")
        assert response.status_code == 200

        logs = get_access_logs()
        assert len(logs) == 1
        assert logs[0].user_id == "auditor-001"
        assert logs[0].result == "denied"

    def test_access_request_creates_log_entry(self, client: TestClient) -> None:
        """An access request via POST should produce an audit log entry."""
        response = client.post(
            "/api/v1/access/request",
            json={
                "user_id": "analyst-001",
                "dataset_id": "marts_finance.dim_accounts",
                "permission": "read",
                "reason": "Quarterly report preparation",
            },
        )
        assert response.status_code == 200

        logs = get_access_logs()
        assert len(logs) == 1
        assert logs[0].action == "request"
        assert logs[0].permission == "read"

    def test_multiple_checks_create_multiple_entries(self, client: TestClient) -> None:
        """Each access check creates its own log entry."""
        client.get("/api/v1/access/check/admin-001/staging.test1")
        client.get("/api/v1/access/check/admin-001/staging.test2")
        client.get("/api/v1/access/check/analyst-001/staging.test3")

        logs = get_access_logs()
        assert len(logs) == 3


class TestAuditTrailFiltering:
    """Verify that the audit trail can be filtered by dataset."""

    def test_filter_by_dataset_id(self, client: TestClient) -> None:
        """Audit trail endpoint returns only logs for the specified dataset."""
        client.get("/api/v1/access/check/admin-001/staging.test1")
        client.get("/api/v1/access/check/admin-001/staging.test2")
        client.get("/api/v1/access/check/admin-001/staging.test1")

        response = client.get("/api/v1/access/audit/staging.test1")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 2
        for entry in data:
            assert entry["dataset_id"] == "staging.test1"

    def test_audit_trail_limit(self, client: TestClient) -> None:
        """Audit trail respects the limit parameter."""
        for i in range(5):
            client.get(f"/api/v1/access/check/admin-001/staging.table_{i}")

        # All logs share different datasets, query one that has all 5
        # Actually, let's query with limit across all by creating same dataset entries
        for i in range(5):
            client.get("/api/v1/access/check/admin-001/staging.same_table")

        response = client.get("/api/v1/access/audit/staging.same_table?limit=3")
        assert response.status_code == 200
        data = response.json()
        assert len(data) == 3

    def test_empty_audit_trail(self, client: TestClient) -> None:
        """Audit trail for a dataset with no access returns empty list."""
        response = client.get("/api/v1/access/audit/nonexistent.dataset")
        assert response.status_code == 200
        data = response.json()
        assert data == []


class TestAuditLogEntryFields:
    """Verify that log entries contain all required fields."""

    def test_log_entry_has_timestamp(self, client: TestClient) -> None:
        """Every log entry must have a timestamp."""
        client.get("/api/v1/access/check/admin-001/staging.test")
        logs = get_access_logs()
        assert logs[0].timestamp is not None

    def test_log_entry_has_log_id(self, client: TestClient) -> None:
        """Every log entry must have a unique log_id."""
        client.get("/api/v1/access/check/admin-001/staging.test1")
        client.get("/api/v1/access/check/admin-001/staging.test2")
        logs = get_access_logs()
        assert logs[0].log_id != logs[1].log_id

    def test_log_entry_has_ip_address(self, client: TestClient) -> None:
        """Log entry should capture the client IP address."""
        client.get("/api/v1/access/check/admin-001/staging.test")
        logs = get_access_logs()
        assert logs[0].ip_address is not None

    def test_log_entry_has_user_agent(self, client: TestClient) -> None:
        """Log entry should capture the User-Agent header."""
        client.get(
            "/api/v1/access/check/admin-001/staging.test",
            headers={"User-Agent": "test-agent/1.0"},
        )
        logs = get_access_logs()
        assert logs[0].user_agent == "test-agent/1.0"

    def test_log_entry_has_role(self, client: TestClient) -> None:
        """Log entry should record the user's role."""
        client.get("/api/v1/access/check/analyst-001/marts_finance.dim_accounts")
        logs = get_access_logs()
        assert logs[0].role == "finance_analyst"

    def test_log_entry_has_matched_pattern_on_grant(self, client: TestClient) -> None:
        """Granted log entries should include the matched pattern."""
        client.get("/api/v1/access/check/admin-001/staging.test")
        logs = get_access_logs()
        assert logs[0].matched_pattern == "*"

    def test_log_entry_has_no_matched_pattern_on_deny(self, client: TestClient) -> None:
        """Denied log entries should have None for matched_pattern."""
        client.get("/api/v1/access/check/auditor-001/staging.test")
        logs = get_access_logs()
        assert logs[0].matched_pattern is None


class TestPermissionChangeAuditLogging:
    """Verify that grant/revoke operations are properly logged."""

    def test_grant_creates_permission_change_entry(self, client: TestClient) -> None:
        """Granting access should produce a permission change log entry."""
        response = client.post(
            "/api/v1/access/grant",
            json={
                "admin_user_id": "admin-001",
                "target_user_id": "analyst-001",
                "dataset_id": "staging.new_table",
                "permission": "read",
                "reason": "Temporary access for investigation",
            },
        )
        assert response.status_code == 200

        changes = get_permission_changes()
        assert len(changes) == 1
        assert changes[0].action == "grant"
        assert changes[0].admin_user_id == "admin-001"
        assert changes[0].target_user_id == "analyst-001"
        assert changes[0].dataset_id == "staging.new_table"
        assert changes[0].permission == "read"
        assert changes[0].reason == "Temporary access for investigation"

    def test_revoke_creates_permission_change_entry(self, client: TestClient) -> None:
        """Revoking access should produce a permission change log entry."""
        response = client.post(
            "/api/v1/access/revoke",
            json={
                "admin_user_id": "admin-001",
                "target_user_id": "analyst-001",
                "dataset_id": "staging.new_table",
                "permission": "read",
                "reason": "Investigation complete",
            },
        )
        assert response.status_code == 200

        changes = get_permission_changes()
        assert len(changes) == 1
        assert changes[0].action == "revoke"

    def test_non_admin_grant_does_not_log(self, client: TestClient) -> None:
        """A failed grant attempt (non-admin) should not create a change entry."""
        response = client.post(
            "/api/v1/access/grant",
            json={
                "admin_user_id": "analyst-001",
                "target_user_id": "engineer-001",
                "dataset_id": "staging.test",
                "permission": "read",
                "reason": "Trying to escalate",
            },
        )
        assert response.status_code == 403

        changes = get_permission_changes()
        assert len(changes) == 0

    def test_permission_change_has_timestamp(self, client: TestClient) -> None:
        """Permission change entries must have a timestamp."""
        client.post(
            "/api/v1/access/grant",
            json={
                "admin_user_id": "admin-001",
                "target_user_id": "analyst-001",
                "dataset_id": "staging.test",
                "permission": "read",
                "reason": "Test",
            },
        )
        changes = get_permission_changes()
        assert changes[0].timestamp is not None

    def test_permission_change_has_unique_log_id(self, client: TestClient) -> None:
        """Each permission change entry should have a unique log_id."""
        for _ in range(3):
            client.post(
                "/api/v1/access/grant",
                json={
                    "admin_user_id": "admin-001",
                    "target_user_id": "analyst-001",
                    "dataset_id": "staging.test",
                    "permission": "read",
                    "reason": "Test",
                },
            )
        changes = get_permission_changes()
        log_ids = [c.log_id for c in changes]
        assert len(log_ids) == len(set(log_ids)), "Log IDs must be unique"
