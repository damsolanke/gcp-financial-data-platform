# Governance Service (Module D)

RBAC-based access control and audit logging for the GCP Financial Data Platform. Evaluates role-based permissions on dataset patterns and records every check, grant and revoke.

What is real in this reference implementation: the RBAC engine, the HTTP API, and the IAM-binding generator/validator, all covered by 110 tests. The user store (`app/routes/access.py`, `USERS`) and the audit log (`app/services/audit_logger.py`) are in-memory; nothing is written to BigQuery yet, and `iam_sync` generates Terraform HCL / binding dicts without applying them.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/access/request` | Request access to a dataset (evaluates against RBAC policy) |
| `GET` | `/api/v1/access/check/{user_id}/{dataset_id}` | Check if a user has a specific permission on a dataset |
| `GET` | `/api/v1/access/audit/{dataset_id}` | Retrieve the audit trail for a dataset |
| `POST` | `/api/v1/access/grant` | Grant access to a user (admin only) |
| `POST` | `/api/v1/access/revoke` | Revoke access from a user (admin only) |
| `GET` | `/api/v1/access/policies` | List all active RBAC policies |
| `GET` | `/healthz` | Health check |

## RBAC Model

Roles map to job functions. Each role is granted a set of permissions on dataset patterns using glob-style matching. Patterns use the *logical* layer name (`marts_finance.<table>`); the physical BigQuery dataset is `fdp_<env>_<layer>` (see `terraform/modules/bigquery`).

| Role | Dataset Pattern | Permissions |
|------|----------------|-------------|
| `admin` | `*` | read, write, admin |
| `finance_analyst` | `marts_finance.*`, `marts_analytics.*` | read |
| `data_engineer` | `staging.*`, `intermediate.*` | read, write |
| `data_engineer` | `marts_analytics.*` | read |
| `executive` | `marts_finance.*`, `marts_analytics.*` | read |
| `auditor` | `audit.*` | read |

## Configuration

All settings come from the environment (`app/config.py`):

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8081` | HTTP listen port (Dockerfile and the Kubernetes module use 8081) |
| `LOG_LEVEL` | `info` | Log level |
| `ENVIRONMENT` | `dev` | `dev`, `staging` or `prod`; also derives the audit dataset |
| `BIGQUERY_PROJECT_ID` | `local-project` | GCP project for the (future) BigQuery audit sink |
| `BIGQUERY_DATASET_AUDIT` | `fdp_<ENVIRONMENT>_audit` | Audit dataset, following the platform's `fdp_<env>_<layer>` scheme |
| `SECRET_KEY` | `change-me-in-production` | Token signing secret (no endpoint issues tokens yet) |

## Local Development

```bash
cd governance
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8081
```

## Testing and Linting

```bash
pytest tests/ -v --cov=app --cov-report=term-missing
ruff check .                          # rule set pinned in ruff.toml
mypy app/ --ignore-missing-imports
```

## Docker

```bash
docker build -t governance .
docker run -p 8081:8081 governance
```
