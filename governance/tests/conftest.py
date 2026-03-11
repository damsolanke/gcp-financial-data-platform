"""Shared test fixtures."""

import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.services.audit_logger import _access_logs, _permission_changes


@pytest.fixture
def client() -> TestClient:
    """Create a FastAPI test client.

    Returns:
        A TestClient instance bound to the governance app.
    """
    return TestClient(app)


@pytest.fixture(autouse=True)
def clear_audit_logs():
    """Clear audit logs between tests to ensure isolation."""
    _access_logs.clear()
    _permission_changes.clear()
    yield
    _access_logs.clear()
    _permission_changes.clear()
