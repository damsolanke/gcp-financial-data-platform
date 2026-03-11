"""IAM sync tests.

Verifies that the IAM binding generation and validation logic produces
correct, secure output aligned with GCP best practices.
"""

from app.models.rbac import Role
from app.services.iam_sync import (
    generate_terraform_iam,
    generate_iam_bindings,
    validate_bindings,
)


# ---------------------------------------------------------------------------
# Sample service account emails for testing
# ---------------------------------------------------------------------------
SAMPLE_SA_EMAILS: dict[Role, str] = {
    Role.ADMIN: "admin-sa@project.iam.gserviceaccount.com",
    Role.FINANCE_ANALYST: "analyst-sa@project.iam.gserviceaccount.com",
    Role.DATA_ENGINEER: "engineer-sa@project.iam.gserviceaccount.com",
    Role.EXECUTIVE: "executive-sa@project.iam.gserviceaccount.com",
    Role.AUDITOR: "auditor-sa@project.iam.gserviceaccount.com",
}


class TestGenerateTerraformIAM:
    """Tests for Terraform HCL generation."""

    def test_produces_non_empty_output(self) -> None:
        """Terraform output should not be empty when service accounts are provided."""
        result = generate_terraform_iam(SAMPLE_SA_EMAILS)
        assert len(result) > 0

    def test_contains_resource_blocks(self) -> None:
        """Output should contain Terraform resource blocks."""
        result = generate_terraform_iam(SAMPLE_SA_EMAILS)
        assert 'resource "google_bigquery_dataset_iam_member"' in result

    def test_contains_service_account_members(self) -> None:
        """Output should reference service account emails."""
        result = generate_terraform_iam(SAMPLE_SA_EMAILS)
        assert "serviceAccount:admin-sa@project.iam.gserviceaccount.com" in result
        assert "serviceAccount:analyst-sa@project.iam.gserviceaccount.com" in result

    def test_contains_gcp_iam_roles(self) -> None:
        """Output should reference predefined GCP IAM roles."""
        result = generate_terraform_iam(SAMPLE_SA_EMAILS)
        assert "roles/bigquery.dataViewer" in result
        assert "roles/bigquery.admin" in result

    def test_empty_service_accounts_produces_empty_output(self) -> None:
        """No service accounts means no Terraform output."""
        result = generate_terraform_iam({})
        assert result == ""

    def test_partial_service_accounts(self) -> None:
        """Only roles with service accounts should appear in output."""
        partial = {Role.ADMIN: "admin-sa@project.iam.gserviceaccount.com"}
        result = generate_terraform_iam(partial)
        assert "admin-sa@project.iam.gserviceaccount.com" in result
        assert "analyst-sa@project.iam.gserviceaccount.com" not in result

    def test_no_primitive_roles_in_terraform(self) -> None:
        """Generated Terraform must never use primitive roles."""
        result = generate_terraform_iam(SAMPLE_SA_EMAILS)
        assert "roles/owner" not in result.lower()
        assert "roles/editor" not in result.lower()
        assert "roles/viewer" not in result.lower()


class TestGenerateIAMBindings:
    """Tests for IAM binding dict generation."""

    def test_produces_non_empty_list(self) -> None:
        """Bindings list should not be empty when service accounts are provided."""
        bindings = generate_iam_bindings(SAMPLE_SA_EMAILS)
        assert len(bindings) > 0

    def test_binding_structure(self) -> None:
        """Each binding should have the required keys."""
        bindings = generate_iam_bindings(SAMPLE_SA_EMAILS)
        required_keys = {"dataset_id", "role", "member", "app_role", "permission"}
        for binding in bindings:
            assert required_keys.issubset(binding.keys()), (
                f"Binding missing keys: {required_keys - binding.keys()}"
            )

    def test_all_members_are_service_accounts(self) -> None:
        """All members in generated bindings must be service accounts."""
        bindings = generate_iam_bindings(SAMPLE_SA_EMAILS)
        for binding in bindings:
            assert binding["member"].startswith("serviceAccount:"), (
                f"Member '{binding['member']}' is not a service account"
            )

    def test_no_primitive_roles_in_bindings(self) -> None:
        """Generated bindings must not contain primitive IAM roles."""
        bindings = generate_iam_bindings(SAMPLE_SA_EMAILS)
        primitive_roles = {"roles/owner", "roles/editor", "roles/viewer"}
        for binding in bindings:
            assert binding["role"] not in primitive_roles, (
                f"Primitive role '{binding['role']}' found in bindings"
            )

    def test_empty_service_accounts_produces_empty_list(self) -> None:
        """No service accounts means no bindings."""
        bindings = generate_iam_bindings({})
        assert bindings == []

    def test_admin_produces_multiple_bindings(self) -> None:
        """Admin role should produce bindings for multiple permission levels."""
        admin_only = {Role.ADMIN: "admin-sa@project.iam.gserviceaccount.com"}
        bindings = generate_iam_bindings(admin_only)
        assert len(bindings) >= 3  # read, write, admin on wildcard

    def test_analyst_produces_viewer_only(self) -> None:
        """Finance analyst should only get dataViewer bindings."""
        analyst_only = {Role.FINANCE_ANALYST: "analyst-sa@project.iam.gserviceaccount.com"}
        bindings = generate_iam_bindings(analyst_only)
        for binding in bindings:
            assert binding["role"] == "roles/bigquery.dataViewer"


class TestValidateBindings:
    """Tests for IAM binding validation."""

    def test_valid_bindings_pass(self) -> None:
        """Valid service account bindings should produce no violations."""
        bindings = generate_iam_bindings(SAMPLE_SA_EMAILS)
        violations = validate_bindings(bindings)
        assert violations == [], f"Unexpected violations: {violations}"

    def test_catches_primitive_role_owner(self) -> None:
        """Validator should flag roles/owner."""
        bindings = [
            {
                "dataset_id": "staging.*",
                "role": "roles/owner",
                "member": "serviceAccount:test@project.iam.gserviceaccount.com",
            }
        ]
        violations = validate_bindings(bindings)
        assert len(violations) == 1
        assert "primitive role" in violations[0].lower()

    def test_catches_primitive_role_editor(self) -> None:
        """Validator should flag roles/editor."""
        bindings = [
            {
                "dataset_id": "staging.*",
                "role": "roles/editor",
                "member": "serviceAccount:test@project.iam.gserviceaccount.com",
            }
        ]
        violations = validate_bindings(bindings)
        assert len(violations) == 1
        assert "primitive role" in violations[0].lower()

    def test_catches_primitive_role_viewer(self) -> None:
        """Validator should flag roles/viewer."""
        bindings = [
            {
                "dataset_id": "staging.*",
                "role": "roles/viewer",
                "member": "serviceAccount:test@project.iam.gserviceaccount.com",
            }
        ]
        violations = validate_bindings(bindings)
        assert len(violations) == 1
        assert "primitive role" in violations[0].lower()

    def test_catches_allUsers(self) -> None:
        """Validator should flag allUsers member."""
        bindings = [
            {
                "dataset_id": "staging.*",
                "role": "roles/bigquery.dataViewer",
                "member": "allUsers",
            }
        ]
        violations = validate_bindings(bindings)
        assert len(violations) >= 1
        assert any("allUsers" in v for v in violations)

    def test_catches_allAuthenticatedUsers(self) -> None:
        """Validator should flag allAuthenticatedUsers member."""
        bindings = [
            {
                "dataset_id": "staging.*",
                "role": "roles/bigquery.dataViewer",
                "member": "allAuthenticatedUsers",
            }
        ]
        violations = validate_bindings(bindings)
        assert len(violations) >= 1
        assert any("allAuthenticatedUsers" in v for v in violations)

    def test_catches_user_email_instead_of_service_account(self) -> None:
        """Validator should flag user: email members."""
        bindings = [
            {
                "dataset_id": "staging.*",
                "role": "roles/bigquery.dataViewer",
                "member": "user:alice@company.com",
            }
        ]
        violations = validate_bindings(bindings)
        assert len(violations) == 1
        assert "not a service account" in violations[0].lower()

    def test_multiple_violations(self) -> None:
        """Validator should report all violations, not just the first."""
        bindings = [
            {
                "dataset_id": "staging.*",
                "role": "roles/owner",
                "member": "allUsers",
            },
            {
                "dataset_id": "marts.*",
                "role": "roles/editor",
                "member": "user:bob@company.com",
            },
        ]
        violations = validate_bindings(bindings)
        # First binding: primitive role + allUsers = at least 2 violations
        # Second binding: primitive role + user email = at least 2 violations
        assert len(violations) >= 4

    def test_empty_bindings_pass(self) -> None:
        """No bindings means no violations."""
        violations = validate_bindings([])
        assert violations == []

    def test_valid_service_account_passes(self) -> None:
        """A properly formatted service account binding should pass."""
        bindings = [
            {
                "dataset_id": "staging.*",
                "role": "roles/bigquery.dataViewer",
                "member": "serviceAccount:my-sa@project.iam.gserviceaccount.com",
            }
        ]
        violations = validate_bindings(bindings)
        assert violations == []
