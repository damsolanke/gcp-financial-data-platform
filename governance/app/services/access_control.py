"""RBAC evaluation engine.

This is the core authorization logic. It's deliberately simple --
RBAC with glob-style dataset matching. ABAC is a future enhancement
for when we need attribute-based conditions (time-of-day, IP range,
data classification level).
"""

from fnmatch import fnmatch
from ..models.rbac import (
    Role,
    Permission,
    AccessDecision,
    AccessCheckResult,
    ROLE_PERMISSIONS,
)


def check_access(
    role: Role,
    dataset_id: str,
    permission: Permission,
    user_id: str = "",
) -> AccessCheckResult:
    """Evaluate whether a role has a specific permission on a dataset.

    Iterates through the role's permission patterns and returns GRANTED
    on first match. Returns DENIED if no pattern matches.

    Args:
        role: The user's assigned role.
        dataset_id: The fully-qualified dataset identifier (e.g. "staging.stg_revenue").
        permission: The permission being requested (read, write, admin).
        user_id: The user identifier for the result object.

    Returns:
        AccessCheckResult with the decision and matched pattern (if any).
    """
    role_patterns = ROLE_PERMISSIONS.get(role, {})

    for pattern, allowed_permissions in role_patterns.items():
        if fnmatch(dataset_id, pattern) and permission in allowed_permissions:
            return AccessCheckResult(
                user_id=user_id,
                dataset_id=dataset_id,
                permission=permission,
                decision=AccessDecision.GRANTED,
                role=role,
                matched_pattern=pattern,
            )

    return AccessCheckResult(
        user_id=user_id,
        dataset_id=dataset_id,
        permission=permission,
        decision=AccessDecision.DENIED,
        role=role,
        matched_pattern=None,
    )
