# Governance Service (Module D)

RBAC-based access control and audit logging for the GCP Financial Data Platform. Enforces role-based permissions on BigQuery datasets and produces a full audit trail for SOX/ITGC compliance.

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

Roles map to job functions. Each role is granted a set of permissions on dataset patterns using glob-style matching.

| Role | Dataset Pattern | Permissions |
|------|----------------|-------------|
| `admin` | `*` | read, write, admin |
| `finance_analyst` | `marts_finance.*`, `marts_analytics.*` | read |
| `data_engineer` | `staging.*`, `intermediate.*` | read, write |
| `data_engineer` | `marts_analytics.*` | read |
| `executive` | `marts_finance.*`, `marts_analytics.*` | read |
| `auditor` | `audit.*` | read |

## Local Development

```bash
cd governance
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8081
```

## Testing

```bash
pytest tests/ -v --cov=app --cov-report=term-missing
```

## Docker

```bash
docker build -t governance .
docker run -p 8081:8081 governance
```
