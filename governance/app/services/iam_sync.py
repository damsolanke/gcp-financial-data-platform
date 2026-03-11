"""IAM policy sync -- generates GCP IAM bindings from RBAC configuration.

Reads the RBAC permission matrix and produces either:
1. Terraform-compatible HCL for BigQuery dataset IAM bindings
2. Direct API calls via google-cloud-bigquery SDK

This ensures the BigQuery-level permissions always match the application RBAC.
"""

from typing import Any

from ..models.rbac import ROLE_PERMISSIONS, Role, Permission


# Mapping from application roles to GCP IAM roles
ROLE_TO_GCP_IAM: dict[tuple[Role, Permission], str] = {
    (Role.ADMIN, Permission.ADMIN): "roles/bigquery.admin",
    (Role.ADMIN, Permission.WRITE): "roles/bigquery.dataEditor",
    (Role.ADMIN, Permission.READ): "roles/bigquery.dataViewer",
    (Role.FINANCE_ANALYST, Permission.READ): "roles/bigquery.dataViewer",
    (Role.DATA_ENGINEER, Permission.READ): "roles/bigquery.dataViewer",
    (Role.DATA_ENGINEER, Permission.WRITE): "roles/bigquery.dataEditor",
    (Role.EXECUTIVE, Permission.READ): "roles/bigquery.dataViewer",
    (Role.AUDITOR, Permission.READ): "roles/bigquery.dataViewer",
}


def generate_terraform_iam(
    service_account_emails: dict[Role, str],
) -> str:
    """Generate Terraform HCL for BigQuery dataset IAM bindings.

    Produces a resource block for each role/dataset-pattern/permission
    combination in the RBAC matrix, using the corresponding GCP IAM role.

    Args:
        service_account_emails: Mapping of application role to GCP service
            account email address.

    Returns:
        A string containing Terraform HCL resource definitions.
    """
    blocks: list[str] = []

    for app_role, patterns in ROLE_PERMISSIONS.items():
        sa_email = service_account_emails.get(app_role)
        if not sa_email:
            continue

        for pattern, permissions in patterns.items():
            # Sanitise the pattern for use as a Terraform resource name
            safe_pattern = pattern.replace("*", "all").replace(".", "_")

            for perm in sorted(permissions, key=lambda p: p.value):
                iam_role = ROLE_TO_GCP_IAM.get((app_role, perm))
                if not iam_role:
                    continue

                resource_name = f"{app_role.value}_{safe_pattern}_{perm.value}"
                block = (
                    f'resource "google_bigquery_dataset_iam_member" "{resource_name}" {{\n'
                    f'  dataset_id = "{pattern}"\n'
                    f'  role       = "{iam_role}"\n'
                    f'  member     = "serviceAccount:{sa_email}"\n'
                    f"}}\n"
                )
                blocks.append(block)

    return "\n".join(blocks)


def generate_iam_bindings(
    service_account_emails: dict[Role, str],
) -> list[dict[str, Any]]:
    """Generate IAM binding dicts for direct API application.

    Each binding contains the dataset pattern, GCP IAM role, and the
    service account member string ready for the BigQuery API.

    Args:
        service_account_emails: Mapping of application role to GCP service
            account email address.

    Returns:
        List of binding dictionaries with keys: dataset_id, role, member,
        app_role, and permission.
    """
    bindings: list[dict[str, Any]] = []

    for app_role, patterns in ROLE_PERMISSIONS.items():
        sa_email = service_account_emails.get(app_role)
        if not sa_email:
            continue

        for pattern, permissions in patterns.items():
            for perm in sorted(permissions, key=lambda p: p.value):
                iam_role = ROLE_TO_GCP_IAM.get((app_role, perm))
                if not iam_role:
                    continue

                bindings.append(
                    {
                        "dataset_id": pattern,
                        "role": iam_role,
                        "member": f"serviceAccount:{sa_email}",
                        "app_role": app_role.value,
                        "permission": perm.value,
                    }
                )

    return bindings


def validate_bindings(bindings: list[dict[str, Any]]) -> list[str]:
    """Validate that bindings follow security best practices.

    Checks for common IAM misconfigurations:
    - No primitive roles (Owner, Editor, Viewer)
    - No allUsers or allAuthenticatedUsers
    - Every binding has a service account (not user email)

    Args:
        bindings: List of IAM binding dictionaries to validate.

    Returns:
        List of violation messages. Empty list means all bindings are valid.
    """
    violations: list[str] = []

    primitive_roles = {"roles/owner", "roles/editor", "roles/viewer"}

    for i, binding in enumerate(bindings):
        role = binding.get("role", "")
        member = binding.get("member", "")

        # Check for primitive roles
        if role.lower() in primitive_roles:
            violations.append(
                f"Binding {i}: primitive role '{role}' is not allowed. "
                f"Use predefined or custom roles instead."
            )

        # Check for allUsers or allAuthenticatedUsers
        if member in ("allUsers", "allAuthenticatedUsers"):
            violations.append(
                f"Binding {i}: member '{member}' grants public access "
                f"and is not allowed for financial data."
            )

        # Check that member uses a service account, not a user email
        if member and not member.startswith("serviceAccount:"):
            if member not in ("allUsers", "allAuthenticatedUsers"):
                violations.append(
                    f"Binding {i}: member '{member}' is not a service account. "
                    f"All bindings must use service accounts, not user emails."
                )

    return violations
