"""Governance service -- data access control and audit logging."""

import structlog
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .routes import access, policies

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
)
logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler for startup/shutdown logging."""
    logger.info(
        "governance_service_starting",
        port=settings.port,
        environment=settings.environment,
    )
    yield
    logger.info("governance_service_stopping")


app = FastAPI(
    title="Financial Data Governance Service",
    description="RBAC-based access control and audit logging for the financial data platform.",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(access.router)
app.include_router(policies.router)


@app.get("/healthz")
async def health_check() -> dict:
    """Health check endpoint for load balancers and orchestrators.

    Returns:
        Dictionary with service status and environment.
    """
    return {
        "status": "healthy",
        "service": "governance",
        "environment": settings.environment,
    }


@app.middleware("http")
async def audit_middleware(request: Request, call_next) -> Response:
    """Log every API request for audit trail.

    Args:
        request: The incoming HTTP request.
        call_next: The next middleware or route handler.

    Returns:
        The HTTP response after logging.
    """
    response = await call_next(request)
    logger.info(
        "http_request",
        method=request.method,
        path=request.url.path,
        status=response.status_code,
        client=request.client.host if request.client else "unknown",
    )
    return response
