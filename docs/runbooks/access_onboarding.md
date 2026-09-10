# Access Onboarding Runbook

This runbook covers granting, verifying, and auditing data access for new users of the Financial Data Platform.

---

## Overview

All data access is governed by Role-Based Access Control (RBAC). Users are assigned a single role that determines which datasets they can access and at what permission level. Every access check and permission change is logged to the audit trail.

RBAC patterns use the *logical* layer name (`marts_finance.<table>`, `staging.<table>`); the physical BigQuery datasets are `fdp_<env>_<layer>` (for example `fdp_prod_marts_finance`). The governance service's user store and audit log are in-memory in this reference implementation (`governance/app/routes/access.py`, `governance/app/services/audit_logger.py`); entries do not survive a restart and are not written to BigQuery.

### Available Roles

| Role | Datasets Accessible | Permission | Typical Job Function |
|------|-------------------|------------|---------------------|
| `admin` | `*` (all datasets) | read, write, admin | Platform administrators |
| `finance_analyst` | `marts_finance.*`, `marts_analytics.*` | read | Financial analysts, FP&A |
| `data_engineer` | `staging.*`, `intermediate.*`, `marts_analytics.*` | read, write (staging/intermediate), read (marts) | Data engineers, analytics engineers |
| `executive` | `marts_finance.*`, `marts_analytics.*` | read | C-suite, VP-level leadership |
| `auditor` | `audit.*` | read | Compliance, internal audit |

### Dataset Patterns

The RBAC engine uses glob-style matching. A role with access to `marts_finance.*` can access any table in the `marts_finance` dataset:
- `marts_finance.fct_daily_revenue_summary` -- matches
- `marts_finance.fct_monthly_cost_attribution` -- matches
- `staging.stg_revenue_transactions` -- does NOT match

---

## Step 1: Determine the Appropriate Role

Use the following decision tree:

```
What is the user's job function?
│
├── Manages the data platform infrastructure?
│   └── Role: admin
│
├── Builds or maintains data pipelines and dbt models?
│   └── Role: data_engineer
│
├── Analyzes financial data for reporting and forecasting?
│   └── Role: finance_analyst
│
├── Needs executive dashboards and high-level metrics?
│   └── Role: executive
│
├── Performs compliance audits or access reviews?
│   └── Role: auditor
│
└── None of the above?
    └── Contact the data team to discuss a custom role or
        determine which existing role best fits
```

**Principle of least privilege:** Always assign the most restrictive role that allows the user to perform their job function. If a finance analyst also needs to debug pipeline issues, they should request `data_engineer` access separately with documented justification, not be given `admin`.

---

## Step 2: Create User Entry in Governance Service

### Option A: Add to the User Store

Users exist only in the `USERS` dictionary in `governance/app/routes/access.py`; the grant endpoint records the permission change for an *existing* user and returns 404 for an unknown `target_user_id`. Add the user there first (see Option B), deploy, then record the grant:

```bash
# Record the grant in the permission-change audit log
curl -X POST http://governance-service:8081/api/v1/access/grant \
  -H "Content-Type: application/json" \
  -d '{
    "admin_user_id": "admin-001",
    "target_user_id": "NEW_USER_ID",
    "dataset_id": "marts_finance.*",
    "permission": "read",
    "reason": "Onboarding: [NAME], [ROLE], approved by [APPROVER] on [DATE]"
  }'
```

**Required fields:**
- `admin_user_id`: The admin performing the grant (must have the `admin` role)
- `target_user_id`: The new user's identifier (use email prefix or employee ID)
- `dataset_id`: The dataset pattern to grant access to
- `permission`: `read`, `write`, or `admin`
- `reason`: Free-text justification (required for audit trail)

### Option B: Edit the User Store

The user store is the `USERS` dictionary in `governance/app/routes/access.py`. In a production deployment this would be backed by a database or identity provider.

```python
# Example: Add a new finance analyst
"analyst-002": User(
    user_id="analyst-002",
    email="jane.doe@company.com",
    role=Role.FINANCE_ANALYST,
    display_name="Jane Doe",
    is_active=True,
),
```

After adding the user, restart the governance service to pick up the change:

```bash
kubectl rollout restart deployment/governance-service -n data-services
```

---

## Step 3: Sync IAM Bindings to BigQuery

The governance service RBAC controls application-level access. For users who also need direct BigQuery access (e.g., via the BigQuery console or a BI tool), the IAM sync must propagate permissions to GCP IAM.

### Generate Terraform IAM Bindings

The IAM sync is a library (`governance/app/services/iam_sync.py`), not an HTTP endpoint. Generate the HCL from the RBAC matrix:

```bash
cd governance && python - <<'PY' > generated_iam.tf
from app.models.rbac import Role
from app.services.iam_sync import generate_terraform_iam

print(generate_terraform_iam({
    Role.FINANCE_ANALYST: "analyst-sa@PROJECT_ID.iam.gserviceaccount.com",
    Role.DATA_ENGINEER: "engineer-sa@PROJECT_ID.iam.gserviceaccount.com",
    Role.EXECUTIVE: "exec-sa@PROJECT_ID.iam.gserviceaccount.com",
    Role.AUDITOR: "auditor-sa@PROJECT_ID.iam.gserviceaccount.com",
}))
PY
```

The generated blocks use the logical pattern (`marts_finance.*`) as `dataset_id`; replace it with the physical `fdp_<env>_marts_finance` dataset and drop the `.*` before applying.

### Apply IAM Bindings

```bash
# Review the generated Terraform
cat generated_iam.tf

# Plan and apply
cd terraform/environments/prod
terraform plan -target=module.iam
terraform apply -target=module.iam
```

### Validate IAM Bindings

```bash
# Verify the user's service account has the correct BigQuery role
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:analyst-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --format="table(bindings.role)"

# Expected output for finance_analyst:
# ROLE
# roles/bigquery.dataViewer
```

---

## Step 4: Verify Access via Check Endpoint

After creating the user and syncing IAM, verify that the RBAC engine grants the expected access.

### Positive Tests (should be GRANTED)

```bash
# Finance analyst accessing a finance mart
curl http://governance-service:8081/api/v1/access/check/NEW_USER_ID/marts_finance.fct_daily_revenue_summary
# Expected: {"decision": "granted", "role": "finance_analyst", "matched_pattern": "marts_finance.*"}

# Finance analyst accessing an analytics mart
curl http://governance-service:8081/api/v1/access/check/NEW_USER_ID/marts_analytics.fct_unit_economics
# Expected: {"decision": "granted", "role": "finance_analyst", "matched_pattern": "marts_analytics.*"}
```

### Negative Tests (should be DENIED)

```bash
# Finance analyst accessing staging data (should be denied)
curl http://governance-service:8081/api/v1/access/check/NEW_USER_ID/staging.stg_revenue_transactions
# Expected: {"decision": "denied", "role": "finance_analyst", "matched_pattern": null}

# Finance analyst trying to write (should be denied -- read only)
curl "http://governance-service:8081/api/v1/access/check/NEW_USER_ID/marts_finance.fct_daily_revenue_summary?permission=write"
# Expected: {"decision": "denied", "role": "finance_analyst", "matched_pattern": null}
```

### Test Matrix by Role

| Role | `staging.*` read | `intermediate.*` read | `marts_finance.*` read | `marts_analytics.*` read | `audit.*` read | Any write |
|------|-----------------|---------------------|----------------------|------------------------|---------------|-----------|
| admin | GRANTED | GRANTED | GRANTED | GRANTED | GRANTED | GRANTED |
| finance_analyst | DENIED | DENIED | GRANTED | GRANTED | DENIED | DENIED |
| data_engineer | GRANTED | GRANTED | DENIED | GRANTED | DENIED | GRANTED (staging, intermediate) |
| executive | DENIED | DENIED | GRANTED | GRANTED | DENIED | DENIED |
| auditor | DENIED | DENIED | DENIED | DENIED | GRANTED | DENIED |

---

## Step 5: Document in Permission Change Audit Log

Every grant is logged by the governance service (`log_permission_change`). The HTTP audit endpoint only exposes *access-check* entries per dataset; permission changes are read in-process:

```bash
# Access-check trail for a dataset (what the API exposes)
curl http://governance-service:8081/api/v1/access/audit/marts_finance.fct_daily_revenue_summary?limit=5

# Permission changes (in-memory; run inside the service process)
cd governance && python -c "from app.services.audit_logger import get_permission_changes; print(get_permission_changes(limit=5))"
```

Each permission-change entry includes:
- `log_id`: Unique identifier for this audit record
- `timestamp`: When the grant was made
- `admin_user_id`: Who approved the access
- `target_user_id`: Who received access
- `dataset_id`: What they can access
- `permission`: At what level (read/write/admin)
- `action`: `grant`
- `reason`: The justification provided in Step 2

---

## Access Review Process

Access should be reviewed quarterly. The following queries support the review:

### List All Active Users and Their Roles

```bash
# Users live in the in-memory store; the policy matrix is exposed over HTTP
grep -n "user_id=" governance/app/routes/access.py
curl http://governance-service:8081/api/v1/access/policies
```

### Review Permission Changes in the Last Quarter

```bash
cd governance && python -c "from app.services.audit_logger import get_permission_changes; print(get_permission_changes(limit=500))"
```

### Identify Unused Access

```bash
# Query the access log to find users who have not accessed their granted datasets
# in the last 90 days. NOTE: nothing writes these BigQuery tables yet (the
# governance service keeps its audit log in memory), so this query is the
# intended shape once the BigQuery sink is wired.
bq query --use_legacy_sql=false \
  "WITH granted_users AS (
     SELECT DISTINCT target_user_id AS user_id, dataset_id
     FROM fdp_prod_audit.permission_changes
     WHERE action = 'grant'
   ),
   recent_access AS (
     SELECT DISTINCT user_id, dataset_id
     FROM fdp_prod_audit.access_log
     WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
       AND result = 'granted'
   )
   SELECT g.user_id, g.dataset_id, 'no_access_in_90_days' AS finding
   FROM granted_users g
   LEFT JOIN recent_access r ON g.user_id = r.user_id AND g.dataset_id = r.dataset_id
   WHERE r.user_id IS NULL"
```

---

## Access Revocation

When a user leaves the team or changes roles:

### Step 1: Revoke via Governance Service

```bash
curl -X POST http://governance-service:8081/api/v1/access/revoke \
  -H "Content-Type: application/json" \
  -d '{
    "admin_user_id": "admin-001",
    "target_user_id": "DEPARTING_USER_ID",
    "dataset_id": "marts_finance.*",
    "permission": "read",
    "reason": "Offboarding: [NAME], last day [DATE], approved by [APPROVER]"
  }'
```

### Step 2: Remove IAM Bindings

```bash
# Remove the user's service account IAM binding
gcloud projects remove-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:user-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataViewer"
```

### Step 3: Deactivate User

Set `is_active: False` in the user store. The RBAC engine will deny all requests from inactive users.

### Step 4: Verify Revocation

```bash
# Confirm access is now denied
curl http://governance-service:8081/api/v1/access/check/DEPARTING_USER_ID/marts_finance.fct_daily_revenue_summary
# Expected: {"decision": "denied"} or HTTP 403 (inactive user)
```

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| User not found (404) | User not in the governance service store | Add user per Step 2 |
| Access denied when it should be granted | Wrong role assigned, or dataset pattern does not match | Verify role in user store, check glob pattern |
| Access granted when it should be denied | Role has broader permissions than intended | Review RBAC matrix in `governance/app/models/rbac.py` |
| IAM binding not taking effect | Terraform not applied, or wrong service account | Re-run IAM sync (Step 3), verify service account email |
| Audit log entry missing | Governance service restarted (the audit store is in-memory) | Expected in this reference implementation; a BigQuery sink is a follow-up |
