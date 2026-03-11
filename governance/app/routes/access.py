"""Access control API endpoints."""

from fastapi import APIRouter, HTTPException, Request

from ..models.rbac import (
    AccessRequest,
    AccessGrant,
    AccessRevocation,
    AccessCheckResult,
    Role,
    Permission,
    User,
)
from ..models.audit import AccessLogEntry, PermissionChangeEntry
from ..services.access_control import check_access
from ..services.audit_logger import log_access, log_permission_change, get_access_logs

router = APIRouter(prefix="/api/v1/access", tags=["access"])

# In-memory user store (in production: backed by database or IAM)
USERS: dict[str, User] = {
    "admin-001": User(
        user_id="admin-001",
        email="admin@company.com",
        role=Role.ADMIN,
        display_name="Platform Admin",
    ),
    "analyst-001": User(
        user_id="analyst-001",
        email="analyst@company.com",
        role=Role.FINANCE_ANALYST,
        display_name="Finance Analyst",
    ),
    "engineer-001": User(
        user_id="engineer-001",
        email="engineer@company.com",
        role=Role.DATA_ENGINEER,
        display_name="Data Engineer",
    ),
    "exec-001": User(
        user_id="exec-001",
        email="cfo@company.com",
        role=Role.EXECUTIVE,
        display_name="CFO",
    ),
    "auditor-001": User(
        user_id="auditor-001",
        email="auditor@company.com",
        role=Role.AUDITOR,
        display_name="Compliance Auditor",
    ),
}


def _get_client_ip(request: Request) -> str:
    """Extract client IP from the request.

    Args:
        request: The incoming FastAPI request.

    Returns:
        The client host IP address, or 'unknown' if unavailable.
    """
    if request and request.client:
        return request.client.host
    return "unknown"


def _get_user_agent(request: Request) -> str:
    """Extract User-Agent header from the request.

    Args:
        request: The incoming FastAPI request.

    Returns:
        The User-Agent string, or 'unknown' if unavailable.
    """
    if request:
        return request.headers.get("user-agent", "unknown")
    return "unknown"


@router.post("/request")
async def request_access(request: AccessRequest, req: Request) -> dict:
    """Request access to a dataset. Evaluates immediately against RBAC policy.

    Args:
        request: The access request containing user_id, dataset_id, and permission.
        req: The raw HTTP request for extracting client metadata.

    Returns:
        Dictionary with the access decision and details.

    Raises:
        HTTPException: 404 if the user is not found, 403 if the user is inactive.
    """
    user = USERS.get(request.user_id)
    if not user:
        raise HTTPException(status_code=404, detail=f"User '{request.user_id}' not found")
    if not user.is_active:
        raise HTTPException(status_code=403, detail=f"User '{request.user_id}' is inactive")

    result = check_access(
        role=user.role,
        dataset_id=request.dataset_id,
        permission=request.permission,
        user_id=request.user_id,
    )

    # Log the access request
    await log_access(
        AccessLogEntry(
            user_id=request.user_id,
            dataset_id=request.dataset_id,
            action="request",
            permission=request.permission.value,
            result=result.decision.value,
            role=user.role.value,
            ip_address=_get_client_ip(req),
            user_agent=_get_user_agent(req),
            matched_pattern=result.matched_pattern,
        )
    )

    return {
        "decision": result.decision.value,
        "user_id": request.user_id,
        "dataset_id": request.dataset_id,
        "permission": request.permission.value,
        "role": user.role.value,
        "matched_pattern": result.matched_pattern,
        "reason": request.reason,
    }


@router.get("/check/{user_id}/{dataset_id}")
async def check_user_access(
    user_id: str,
    dataset_id: str,
    permission: Permission = Permission.READ,
    req: Request,
) -> AccessCheckResult:
    """Check if a user has access to a specific dataset.

    Args:
        user_id: The user to check access for.
        dataset_id: The dataset to check access against.
        permission: The permission level to verify (defaults to READ).
        req: The raw HTTP request for extracting client metadata.

    Returns:
        AccessCheckResult with the decision.

    Raises:
        HTTPException: 404 if the user is not found.
    """
    user = USERS.get(user_id)
    if not user:
        raise HTTPException(status_code=404, detail=f"User '{user_id}' not found")

    result = check_access(
        role=user.role,
        dataset_id=dataset_id,
        permission=permission,
        user_id=user_id,
    )

    # Log the access check
    await log_access(
        AccessLogEntry(
            user_id=user_id,
            dataset_id=dataset_id,
            action="check",
            permission=permission.value,
            result=result.decision.value,
            role=user.role.value,
            ip_address=_get_client_ip(req),
            user_agent=_get_user_agent(req),
            matched_pattern=result.matched_pattern,
        )
    )

    return result


@router.get("/audit/{dataset_id}")
async def get_audit_trail(dataset_id: str, limit: int = 100) -> list[AccessLogEntry]:
    """Get the audit trail for a specific dataset.

    Args:
        dataset_id: The dataset to retrieve audit logs for.
        limit: Maximum number of log entries to return (default 100).

    Returns:
        List of access log entries for the specified dataset.
    """
    return get_access_logs(dataset_id=dataset_id, limit=limit)


@router.post("/grant")
async def grant_access(grant: AccessGrant, req: Request) -> dict:
    """Grant access to a user (admin only).

    Creates a log entry for the permission change. In a production system
    this would also update the IAM bindings and the persistent user store.

    Args:
        grant: The grant request with admin, target user, dataset, and permission.
        req: The raw HTTP request for extracting client metadata.

    Returns:
        Dictionary confirming the grant.

    Raises:
        HTTPException: 404 if admin or target user not found, 403 if requester
            is not an admin.
    """
    admin = USERS.get(grant.admin_user_id)
    if not admin:
        raise HTTPException(
            status_code=404, detail=f"Admin user '{grant.admin_user_id}' not found"
        )
    if admin.role != Role.ADMIN:
        raise HTTPException(
            status_code=403,
            detail=f"User '{grant.admin_user_id}' is not an admin. "
            f"Only admins can grant access.",
        )

    target = USERS.get(grant.target_user_id)
    if not target:
        raise HTTPException(
            status_code=404,
            detail=f"Target user '{grant.target_user_id}' not found",
        )

    # Log the permission change
    await log_permission_change(
        PermissionChangeEntry(
            admin_user_id=grant.admin_user_id,
            target_user_id=grant.target_user_id,
            dataset_id=grant.dataset_id,
            permission=grant.permission.value,
            action="grant",
            reason=grant.reason,
        )
    )

    return {
        "status": "granted",
        "admin_user_id": grant.admin_user_id,
        "target_user_id": grant.target_user_id,
        "dataset_id": grant.dataset_id,
        "permission": grant.permission.value,
        "reason": grant.reason,
    }


@router.post("/revoke")
async def revoke_access(revocation: AccessRevocation, req: Request) -> dict:
    """Revoke access from a user (admin only).

    Creates a log entry for the permission change. In a production system
    this would also update the IAM bindings and the persistent user store.

    Args:
        revocation: The revocation request with admin, target user, dataset,
            and permission.
        req: The raw HTTP request for extracting client metadata.

    Returns:
        Dictionary confirming the revocation.

    Raises:
        HTTPException: 404 if admin or target user not found, 403 if requester
            is not an admin.
    """
    admin = USERS.get(revocation.admin_user_id)
    if not admin:
        raise HTTPException(
            status_code=404,
            detail=f"Admin user '{revocation.admin_user_id}' not found",
        )
    if admin.role != Role.ADMIN:
        raise HTTPException(
            status_code=403,
            detail=f"User '{revocation.admin_user_id}' is not an admin. "
            f"Only admins can revoke access.",
        )

    target = USERS.get(revocation.target_user_id)
    if not target:
        raise HTTPException(
            status_code=404,
            detail=f"Target user '{revocation.target_user_id}' not found",
        )

    # Log the permission change
    await log_permission_change(
        PermissionChangeEntry(
            admin_user_id=revocation.admin_user_id,
            target_user_id=revocation.target_user_id,
            dataset_id=revocation.dataset_id,
            permission=revocation.permission.value,
            action="revoke",
            reason=revocation.reason,
        )
    )

    return {
        "status": "revoked",
        "admin_user_id": revocation.admin_user_id,
        "target_user_id": revocation.target_user_id,
        "dataset_id": revocation.dataset_id,
        "permission": revocation.permission.value,
        "reason": revocation.reason,
    }
