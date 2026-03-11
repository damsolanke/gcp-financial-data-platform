"""Role-Based Access Control model.

Defines the permission matrix that governs who can access what data.
This is the single source of truth for authorization decisions.
"""

from enum import Enum
from typing import Optional

from pydantic import BaseModel


class Role(str, Enum):
    """Roles map to job functions, not individuals."""

    ADMIN = "admin"
    FINANCE_ANALYST = "finance_analyst"
    DATA_ENGINEER = "data_engineer"
    EXECUTIVE = "executive"
    AUDITOR = "auditor"


class Permission(str, Enum):
    READ = "read"
    WRITE = "write"
    ADMIN = "admin"


class AccessDecision(str, Enum):
    GRANTED = "granted"
    DENIED = "denied"


# The permission matrix: role -> dataset pattern -> allowed permissions
# Dataset patterns use glob-style matching (staging.* matches staging.stg_revenue_transactions)
ROLE_PERMISSIONS: dict[Role, dict[str, set[Permission]]] = {
    Role.ADMIN: {
        "*": {Permission.READ, Permission.WRITE, Permission.ADMIN},
    },
    Role.FINANCE_ANALYST: {
        "marts_finance.*": {Permission.READ},
        "marts_analytics.*": {Permission.READ},
    },
    Role.DATA_ENGINEER: {
        "staging.*": {Permission.READ, Permission.WRITE},
        "intermediate.*": {Permission.READ, Permission.WRITE},
        "marts_analytics.*": {Permission.READ},
    },
    Role.EXECUTIVE: {
        "marts_finance.*": {Permission.READ},
        "marts_analytics.*": {Permission.READ},
    },
    Role.AUDITOR: {
        "audit.*": {Permission.READ},
    },
}


class User(BaseModel):
    """A platform user with an assigned role."""

    user_id: str
    email: str
    role: Role
    is_active: bool = True
    display_name: Optional[str] = None


class AccessRequest(BaseModel):
    """A request to access a specific dataset with a given permission."""

    user_id: str
    dataset_id: str
    permission: Permission
    reason: str = ""


class AccessCheckResult(BaseModel):
    """The result of an access check evaluation."""

    user_id: str
    dataset_id: str
    permission: Permission
    decision: AccessDecision
    role: Role
    matched_pattern: Optional[str] = None


class AccessGrant(BaseModel):
    """An administrative grant of access to a user."""

    admin_user_id: str
    target_user_id: str
    dataset_id: str
    permission: Permission
    reason: str


class AccessRevocation(BaseModel):
    """An administrative revocation of access from a user."""

    admin_user_id: str
    target_user_id: str
    dataset_id: str
    permission: Permission
    reason: str


class PolicyRule(BaseModel):
    """A single RBAC policy rule binding a role to dataset permissions."""

    role: Role
    dataset_pattern: str
    permissions: set[Permission]
