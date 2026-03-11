# Access Onboarding Runbook

This runbook covers granting, verifying, and auditing data access for new users of the Financial Data Platform.

---

## Overview

All data access is governed by Role-Based Access Control (RBAC). Users are assigned a single role that determines which datasets they can access and at what permission level. Every access check and permission change is logged to the audit trail.

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

### Option A: API Request (Recommended)

Submit a POST request to create the user. This must be executed by an admin.

```bash
# Create the user entry
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

### Option B: Add to User Store Directly

For initial platform setup or bulk onboarding, add users directly to the governance service user store.

The user store is defined in `governance/app/routes/access.py` (the `USERS` dictionary). In a production deployment, this would be backed by a database or identity provider.

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
kubectl rollout restart deployment/governance-service -n financial-data
```

---

## Step 3: Sync IAM Bindings to BigQuery

The governance service RBAC controls application-level access. For users who also need direct BigQuery access (e.g., via the BigQuery console or a BI tool), the IAM sync must propagate permissions to GCP IAM.

### Generate Terraform IAM Bindings

```bash
# Generate Terraform HCL for BigQuery IAM bindings
curl http://governance-service:8081/api/v1/policies/iam-sync/terraform \
  -H "Content-Type: application/json" \
  -d '{
    "service_account_emails": {
      "finance_analyst": "analyst-sa@PROJECT_ID.iam.gserviceaccount.com",
      "data_engineer": "engineer-sa@PROJECT_ID.iam.gserviceaccount.com",
      "executive": "exec-sa@PROJECT_ID.iam.gserviceaccount.com",
      "auditor": "auditor-sa@PROJECT_ID.iam.gserviceaccount.com"
    }
  }'
```

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

Every access grant is automatically logged by the governance service. Verify the audit entry was created:

```bash
# Check the audit trail for the new user's permission grants
curl http://governance-service:8081/api/v1/access/audit/marts_finance.fct_daily_revenue_summary?limit=5
```

The audit entry includes:
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
curl http://governance-service:8081/api/v1/policies/users
```

### Review Permission Changes in the Last Quarter

```bash
curl http://governance-service:8081/api/v1/policies/changes?limit=500
```

### Identify Unused Access

```bash
# Query the access log to find users who have not accessed their granted datasets
# in the last 90 days
bq query --use_legacy_sql=false \
  "WITH granted_users AS (
     SELECT DISTINCT target_user_id AS user_id, dataset_id
     FROM audit.permission_changes
     WHERE action = 'grant'
   ),
   recent_access AS (
     SELECT DISTINCT user_id, dataset_id
     FROM audit.access_log
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
| Audit log entry missing | Governance service restarted before async write completed | In-memory store issue; production BigQuery backend resolves this |
