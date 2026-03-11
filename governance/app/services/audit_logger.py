"""Audit logging service.

Writes to an in-memory store for development and to BigQuery for production.
Audit logging is async and non-blocking -- it must never slow down access checks.
"""

from typing import Optional

import structlog

from ..models.audit import AccessLogEntry, PermissionChangeEntry

logger = structlog.get_logger()

# In-memory audit store (for development/testing)
_access_logs: list[AccessLogEntry] = []
_permission_changes: list[PermissionChangeEntry] = []


async def log_access(entry: AccessLogEntry) -> None:
    """Log an access check to the audit trail.

    Args:
        entry: The access log entry to persist.
    """
    _access_logs.append(entry)
    logger.info(
        "access_check",
        user_id=entry.user_id,
        dataset_id=entry.dataset_id,
        result=entry.result,
        permission=entry.permission,
    )
    # In production: async BigQuery streaming insert
    # await _write_to_bigquery("audit.access_log", entry.model_dump())


async def log_permission_change(entry: PermissionChangeEntry) -> None:
    """Log a permission grant or revocation.

    Args:
        entry: The permission change entry to persist.
    """
    _permission_changes.append(entry)
    logger.info(
        "permission_change",
        admin=entry.admin_user_id,
        target=entry.target_user_id,
        action=entry.action,
        dataset_id=entry.dataset_id,
    )


def get_access_logs(
    dataset_id: Optional[str] = None, limit: int = 100
) -> list[AccessLogEntry]:
    """Retrieve access logs, optionally filtered by dataset.

    Args:
        dataset_id: If provided, only return logs for this dataset.
        limit: Maximum number of entries to return.

    Returns:
        List of access log entries sorted by timestamp descending.
    """
    logs = _access_logs
    if dataset_id:
        logs = [entry for entry in logs if entry.dataset_id == dataset_id]
    return sorted(logs, key=lambda entry: entry.timestamp, reverse=True)[:limit]


def get_permission_changes(limit: int = 100) -> list[PermissionChangeEntry]:
    """Retrieve permission change history.

    Args:
        limit: Maximum number of entries to return.

    Returns:
        List of permission change entries sorted by timestamp descending.
    """
    return sorted(
        _permission_changes, key=lambda entry: entry.timestamp, reverse=True
    )[:limit]
