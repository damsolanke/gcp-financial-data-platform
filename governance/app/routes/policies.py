"""Policy listing endpoint."""

from fastapi import APIRouter

from ..models.rbac import ROLE_PERMISSIONS

router = APIRouter(prefix="/api/v1/access", tags=["policies"])


@router.get("/policies")
async def list_policies() -> list[dict]:
    """List all active RBAC policies.

    Returns the full permission matrix showing which roles have
    access to which dataset patterns and with what permissions.

    Returns:
        List of policy dictionaries with role, dataset_pattern, and permissions.
    """
    policies: list[dict] = []
    for role, patterns in ROLE_PERMISSIONS.items():
        for pattern, permissions in patterns.items():
            policies.append(
                {
                    "role": role.value,
                    "dataset_pattern": pattern,
                    "permissions": sorted([p.value for p in permissions]),
                }
            )
    return policies
