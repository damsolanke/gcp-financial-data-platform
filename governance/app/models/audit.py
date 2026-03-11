"""Audit log models for compliance (SOX/ITGC alignment)."""

from datetime import datetime
from typing import Optional
from uuid import uuid4

from pydantic import BaseModel, Field


class AccessLogEntry(BaseModel):
    """Logged for every access check -- both granted and denied."""

    log_id: str = Field(default_factory=lambda: str(uuid4()))
    timestamp: datetime = Field(default_factory=datetime.utcnow)
    user_id: str
    dataset_id: str
    action: str  # "check", "request"
    permission: str
    result: str  # "granted", "denied"
    role: str
    ip_address: Optional[str] = None
    user_agent: Optional[str] = None
    session_id: Optional[str] = None
    matched_pattern: Optional[str] = None


class PermissionChangeEntry(BaseModel):
    """Logged for every grant or revocation."""

    log_id: str = Field(default_factory=lambda: str(uuid4()))
    timestamp: datetime = Field(default_factory=datetime.utcnow)
    admin_user_id: str
    target_user_id: str
    dataset_id: str
    permission: str
    action: str  # "grant", "revoke"
    reason: str
