# Incident Response Runbook -- Pipeline Failures

This runbook covers detection, diagnosis, and resolution of failures in the financial data pipeline. For data loss or corruption requiring DR, see [disaster_recovery.md](./disaster_recovery.md).

---

## Alert Triggers and Severity Levels

| Alert | Severity | SLA | Notification |
|-------|----------|-----|-------------|
| Ingestion service health check failing | P1 - Critical | 15 min response | PagerDuty + Slack |
| Pub/Sub DLQ rate >1% of total messages | P1 - Critical | 15 min response | PagerDuty + Slack |
| Airflow DAG `financial_pipeline_daily` failed | P1 - Critical | 30 min response | PagerDuty + Slack |
| Pub/Sub unacked backlog >10K messages | P2 - High | 1 hour response | Slack |
| BigQuery source freshness >24 hours | P2 - High | 1 hour response | Slack |
| dbt test failure | P2 - High | 1 hour response | Slack |
| Anomaly detection alert (>2 sigma) | P3 - Warning | 4 hour response | Slack |
| Ingestion latency p99 >500ms | P3 - Warning | 4 hour response | Slack |
| Airflow DAG SLA miss (>4 hours) | P2 - High | 1 hour response | Slack + Email |

---

## Decision Tree: Which Component Failed?

```
Alert received
│
├── Ingestion service unreachable?
│   └── Go to: Section 1 - Ingestion Service Failures
│
├── Pub/Sub backlog growing?
│   └── Go to: Section 2 - Pub/Sub Issues
│
├── Airflow DAG failed?
│   ├── check_source_freshness failed?
│   │   └── Go to: Section 3.1 - Freshness Check Failure
│   ├── load_to_staging failed?
│   │   └── Go to: Section 3.2 - Staging Load Failure
│   ├── run_dbt_transformations failed?
│   │   └── Go to: Section 3.3 - dbt Run Failure
│   ├── run_dbt_tests failed?
│   │   └── Go to: Section 3.4 - dbt Test Failure
│   ├── run_anomaly_detection fired?
│   │   └── Go to: Section 3.5 - Anomaly Alert
│   └── generate_financial_reports failed?
│       └── Go to: Section 3.6 - Report Generation Failure
│
├── Governance service unreachable?
│   └── Go to: Section 4 - Governance Service Failures
│
└── BigTable latency or errors?
    └── Go to: Section 5 - BigTable Issues
```

---

## Section 1: Ingestion Service Failures

### Symptoms
- Health check (`GET /healthz`) returning non-200 or timing out
- `ingestion_events_received_total` Prometheus counter stopped incrementing
- Pub/Sub validated topic message rate dropped to zero

### Diagnosis

```bash
# Check pod status
kubectl get pods -n data-services -l app=ingestion-service

# Check pod logs (last 100 lines)
kubectl logs -n data-services -l app=ingestion-service --tail=100

# Check for OOM kills or crash loops
kubectl describe pod -n data-services -l app=ingestion-service | grep -A5 "Last State"

# Check resource usage
kubectl top pod -n data-services -l app=ingestion-service
```

### Common Causes and Fixes

#### Pod CrashLoopBackOff
**Cause:** Application panic on startup (usually misconfigured environment variables).
```bash
# Check the environment variables
kubectl get deployment ingestion-service -n data-services -o jsonpath='{.spec.template.spec.containers[0].env}' | jq

# The image is distroless (no shell): check startup errors from the logs instead
kubectl logs -n data-services -l app=ingestion-service --previous --tail=50

# Fix: restart the pod (kills current pod, deployment creates new one)
kubectl rollout restart deployment/ingestion-service -n data-services
```

#### OOMKilled
**Cause:** Memory limit exceeded, usually from large request payloads or connection pool growth.
```bash
# Check current memory limits
kubectl get deployment ingestion-service -n data-services -o jsonpath='{.spec.template.spec.containers[0].resources}'

# Increase memory limit if needed (temporary -- make permanent in terraform/modules/kubernetes)
kubectl set resources deployment/ingestion-service -n data-services --limits=memory=2Gi
```

#### Connection Refused to BigTable
**Cause:** BigTable instance unavailable or network policy blocking traffic.
```bash
# Check BigTable instance status (Terraform names it <instance_name>-<env>)
gcloud bigtable instances describe financial-events-prod

# Verify the BigTable table exists (terraform/modules/bigtable creates financial_events)
cbt -project=PROJECT_ID -instance=financial-events-prod ls

# Check network policies
kubectl get networkpolicy -n data-services
```

### Recovery

After fixing the root cause:
```bash
# Verify pods are healthy
kubectl get pods -n data-services -l app=ingestion-service -w

# Verify health check (port-forward: the image has no shell for kubectl exec)
kubectl port-forward deployment/ingestion-service -n data-services 8080:8080 &
curl -sf http://localhost:8080/healthz

# Send a test event (transaction_id must be a UUID; the schema enforces the format)
curl -X POST 'localhost:8080/api/v1/events?type=revenue_transaction' \
  -H "Content-Type: application/json" \
  -d '{"transaction_id":"550e8400-e29b-41d4-a716-446655440000","timestamp":"2026-03-11T00:00:00Z","amount_cents":100,"currency":"USD","customer_id":"test","product_line":"api_usage","region":"us-east"}'

# Monitor Prometheus metrics for the next 5 minutes
# Then check: http://localhost:8080/metrics
```

---

## Section 2: Pub/Sub Issues

### Symptoms
- Unacknowledged message count growing steadily
- DLQ topic receiving more than 1% of total messages
- Staging tables not receiving new data

### Diagnosis

```bash
# Check subscription backlog
gcloud pubsub subscriptions describe financial-events-validated-sub-prod \
  --format="value(numUndeliveredMessages)"

# Check DLQ message count
gcloud pubsub subscriptions describe financial-events-dlq-sub-prod \
  --format="value(numUndeliveredMessages)"

# Pull sample DLQ messages to understand failure pattern
gcloud pubsub subscriptions pull financial-events-dlq-sub-prod \
  --limit=5 --auto-ack=false --format=json
```

### Common Causes and Fixes

#### Backlog Growing -- Consumer Not Processing
**Cause:** Airflow DAG paused or subscriber service down.
```bash
# Check if the DAG is paused
gcloud composer environments run fdp-composer-prod \
  --location=us-central1 \
  dags list -- -o table | grep financial_pipeline_daily

# Unpause if needed
gcloud composer environments run fdp-composer-prod \
  --location=us-central1 \
  dags unpause -- financial_pipeline_daily
```

#### High DLQ Rate -- Schema Mismatch
**Cause:** Upstream system sending events with unexpected schema.
```bash
# Pull DLQ messages and inspect error attributes
gcloud pubsub subscriptions pull financial-events-dlq-sub-prod \
  --limit=10 --auto-ack=false --format=json | jq '.[].message.attributes'

# Common patterns:
# - Missing required field -> Upstream system changed payload format
# - Invalid enum value -> New product_line or region not in schema
# - Type mismatch -> Upstream sending strings where integers expected
```

**Fix:** Either update the schema to accept the new values (coordinated change) or fix the upstream system.

#### Ack Deadline Expiring
**Cause:** Consumer processing too slowly, messages being redelivered.
```bash
# Increase ack deadline (temporary)
gcloud pubsub subscriptions update financial-events-validated-sub-prod \
  --ack-deadline=600

# Check current deadline
gcloud pubsub subscriptions describe financial-events-validated-sub-prod \
  --format="value(ackDeadlineSeconds)"
```

---

## Section 3: Airflow DAG Failures

### 3.1 Freshness Check Failure

**Task:** `check_source_freshness`
**Cause:** The raw landing table has not been updated in the last 24 hours.

```bash
# Check the most recent ingestion timestamp
bq query --use_legacy_sql=false \
  "SELECT MAX(ingestion_timestamp) AS latest
   FROM fdp_prod_raw.raw_revenue_transactions"
```

**Fix:** This is usually caused by the ingestion service being down or Pub/Sub subscription issues. Diagnose using Sections 1 and 2. Once data is flowing again, clear the failed task and retry:

```bash
gcloud composer environments run fdp-composer-prod \
  --location=us-central1 \
  tasks clear -- financial_pipeline_daily check_source_freshness -y
```

### 3.2 Staging Load Failure

**Task:** `load_to_staging`
**Cause:** BigQuery MERGE into the `fdp_prod_raw` landing tables failed (permissions, quota, or schema mismatch).

```bash
# Check Airflow task logs
gcloud composer environments run fdp-composer-prod \
  --location=us-central1 \
  tasks logs -- financial_pipeline_daily load_to_staging

# Check BigQuery job history for errors
bq ls -j --all=true --max_results=10 --format=json | jq '.[] | select(.status.state == "DONE" and .status.errorResult != null)'
```

**Common fixes:**
- **Quota exceeded:** Wait for quota reset or request increase.
- **Permission denied:** Verify the Airflow service account has `roles/bigquery.dataEditor` on `fdp_prod_raw` (terraform/modules/iam).
- **Schema mismatch:** New columns in source not present in the raw landing table -- update `terraform/modules/bigquery` (and `schemas/`) rather than patching the table by hand.

### 3.3 dbt Run Failure

**Task:** `run_dbt_transformations`
**Cause:** SQL error in a dbt model, BigQuery timeout, or dependency resolution failure.

```bash
# Check the dbt run output in Airflow logs
gcloud composer environments run fdp-composer-prod \
  --location=us-central1 \
  tasks logs -- financial_pipeline_daily run_dbt_transformations

# Run dbt locally against prod to reproduce
cd dbt_project && dbt run --profiles-dir . --target prod --select MODEL_NAME
```

**Common fixes:**
- **SQL syntax error:** Fix the model SQL, commit, and redeploy. Then clear and retry the task.
- **BigQuery timeout:** Increase `execution_timeout` or optimize the query (check for missing partitioning/clustering).
- **Dependency failure:** If an upstream model failed, fix that first, then retry the full chain.

### 3.4 dbt Test Failure

**Task:** `run_dbt_tests`
**Cause:** Data quality issue detected by a dbt test.

**This is NOT necessarily a pipeline bug -- it may indicate real data quality issues upstream.**

```bash
# Check which tests failed
gcloud composer environments run fdp-composer-prod \
  --location=us-central1 \
  tasks logs -- financial_pipeline_daily run_dbt_tests

# Run specific failing tests locally
cd dbt_project && dbt test --profiles-dir . --target prod --select test_name
```

**Decision matrix:**

| Test Type | Action |
|-----------|--------|
| `not_null` on a required field | Investigate upstream -- data should not have nulls. Check ingestion service logs for that time window. |
| `accepted_values` violation | New enum value from upstream (e.g., new product_line). Coordinate schema update or fix upstream. |
| `unique` violation | Deduplication failure in staging MERGE. Check for duplicate event IDs in source data. |
| `relationships` violation (warn) | Informational -- customer has usage but no revenue yet. Generally safe to proceed. |
| `assert_revenue_non_negative` | Critical -- negative revenue should never occur. Investigate the specific transactions. |
| `assert_date_completeness` | Gap in date coverage. Check if the pipeline missed a day or if source data genuinely has a gap. |

**To proceed with reports despite test failure (use with caution):**
```bash
# Clear the test task and allow downstream tasks to run
gcloud composer environments run fdp-composer-prod \
  --location=us-central1 \
  tasks clear -- financial_pipeline_daily run_dbt_tests -y -d
```

### 3.5 Anomaly Alert

**Task:** `run_anomaly_detection`
**Cause:** Total daily revenue (`SUM(total_revenue_usd)` across all product lines and regions) deviated more than 2 standard deviations from the 30-day rolling average.

```bash
# Query the anomaly alerts table (schema: docs/data_model.md, "anomaly_alerts")
bq query --use_legacy_sql=false \
  "SELECT revenue_date, alert_type, severity, daily_revenue, rolling_avg, deviation_sigma, dag_run_id
   FROM fdp_prod_audit.anomaly_alerts
   WHERE detected_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
   ORDER BY deviation_sigma DESC"
```

**Decision matrix:**

| Deviation | Likely Cause | Action |
|-----------|-------------|--------|
| 2-3 sigma | Normal variance, seasonal pattern, or promotional event | Review and dismiss if explainable |
| 3-5 sigma | Billing system issue, price change, or data pipeline error | Investigate with finance team |
| >5 sigma | Critical data issue (wrong currency, duplicate billing, system failure) | Escalate immediately |

**To dismiss a false positive:** Record the reason with the data team; the table has no resolution columns, so keep the alert row as-is for the audit trail.

### 3.6 Report Generation Failure

**Task:** `generate_financial_reports`
**Cause:** Post-dbt reporting query failed.

This task depends on dbt marts being correctly materialized. If dbt run succeeded, the issue is usually in the report-specific SQL or BigQuery permissions.

```bash
# Check task logs
gcloud composer environments run fdp-composer-prod \
  --location=us-central1 \
  tasks logs -- financial_pipeline_daily generate_financial_reports
```

**Fix:** Identify the failing report query, fix the SQL, and retry the task.

---

## Section 4: Governance Service Failures

### Symptoms
- Health check (`GET /healthz`) returning non-200
- Access check requests returning 500
- Audit logs not being written

### Diagnosis

```bash
# Check pod status
kubectl get pods -n data-services -l app=governance-service

# Check pod logs
kubectl logs -n data-services -l app=governance-service --tail=100

# Test health check directly
kubectl exec -it deployment/governance-service -n data-services -- python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8081/healthz').read())"
```

### Common Causes and Fixes

#### Service Crash on Startup
**Cause:** Missing environment variables or import errors.
```bash
kubectl describe pod -n data-services -l app=governance-service | grep -A10 "Events:"
kubectl rollout restart deployment/governance-service -n data-services
```

#### Access Check Returns 500
**Cause:** Internal error in RBAC evaluation or audit logging.
```bash
# Check logs for the specific error
kubectl logs -n data-services -l app=governance-service --tail=50 | grep "ERROR"

# Test with a known good request
curl http://localhost:8081/api/v1/access/check/admin-001/staging.stg_revenue_transactions
```

### Recovery

```bash
# Restart the deployment
kubectl rollout restart deployment/governance-service -n data-services

# Wait for healthy state
kubectl rollout status deployment/governance-service -n data-services --timeout=120s

# Verify access checks work
curl http://localhost:8081/api/v1/access/check/analyst-001/marts_finance.fct_daily_revenue_summary
# Expected: {"decision": "granted", ...}

curl http://localhost:8081/api/v1/access/check/analyst-001/staging.stg_revenue_transactions
# Expected: {"decision": "denied", ...}
```

---

## Section 5: BigTable Issues

### Symptoms
- Ingestion service reporting BigTable write errors
- Hot-path queries returning errors or high latency

### Diagnosis

```bash
# Check instance status (terraform/modules/bigtable: <instance_name>-<env>)
gcloud bigtable instances describe financial-events-prod

# Check cluster nodes and CPU utilization
gcloud bigtable clusters list --instances=financial-events-prod

# Check table row count (approximate)
cbt -project=PROJECT_ID -instance=financial-events-prod count financial_events
```

### Common Causes and Fixes

#### High Latency
**Cause:** Node count too low for current load, hotspotting on row keys.
```bash
# Node count is fixed by Terraform (num_nodes: 1 dev, 3 prod); autoscaling is not configured
gcloud bigtable clusters describe financial-events-prod-cluster --instance=financial-events-prod

# Scale up manually (temporary -- make permanent in terraform/environments/prod)
gcloud bigtable clusters update financial-events-prod-cluster \
  --instance=financial-events-prod \
  --num-nodes=5
```

#### Write Errors
**Cause:** Table does not exist, column family not created, or authentication failure.
```bash
# Verify table exists
cbt -project=PROJECT_ID -instance=financial-events-prod ls

# List column families (expected: event_data, metadata, processing_status)
cbt -project=PROJECT_ID -instance=financial-events-prod ls financial_events

# Recreate the table via Terraform rather than by hand so GC policies are applied
cd terraform/environments/prod && terraform apply -target=module.bigtable
```

---

## Escalation Path

| Level | Who | When |
|-------|-----|------|
| L1 | On-call data engineer | First responder for all P1-P3 alerts |
| L2 | Data engineering team lead | If L1 cannot resolve within 30 minutes, or for any P1 alert |
| L3 | Platform engineering | Infrastructure issues (GKE, networking, IAM) |
| L4 | GCP support | Service-level issues (BigQuery outage, Pub/Sub unavailability) |

**For P1 incidents:**
1. Page the on-call data engineer (PagerDuty)
2. Open an incident channel
3. If no response in 15 minutes, escalate to L2
4. If GCP service issue suspected, file a support case immediately

**For data quality incidents (dbt test failures, anomalies):**
1. Notify the data team in Slack
2. Determine if the issue blocks financial reporting
3. If blocking, escalate to L2 within 1 hour
4. If non-blocking, schedule investigation for next business day
