# Disaster Recovery Runbook

**Recovery Targets:**
- **RTO (Recovery Time Objective):** <45 minutes
- **RPO (Recovery Point Objective):** <1 hour

**Last tested:** Automated monthly DR test via Cloud Scheduler (first Monday of each month, 10:00 UTC)

---

## When to Trigger DR

Initiate this procedure when any of the following are confirmed:

| Trigger | Detection Method | Severity |
|---------|-----------------|----------|
| Data loss detected in BigQuery | Row count monitoring alert, dbt test failure | Critical |
| GCP region failure affecting us-central1 | GCP status dashboard, service unavailability | Critical |
| Data corruption identified | Anomaly detection alert, manual data review | Critical |
| BigTable data loss or unavailability | Health check failure, application errors | High |
| GCS raw bucket data loss | Object count monitoring, backup comparison | High |
| Pub/Sub message loss (subscription reset) | Backlog monitoring, gap in staging data | Medium |

**Decision authority:** On-call data engineer can initiate Steps 1-2. Steps 3+ require incident commander approval.

---

## Pre-Recovery Checklist

Before executing any recovery steps, confirm the following:

- [ ] Incident has been declared and an incident commander assigned
- [ ] Affected scope identified (which datasets, time range, services)
- [ ] Root cause is understood or isolated (prevent re-corruption during restore)
- [ ] Active writes to affected datasets are paused (DAGs disabled, ingestion service scaled to 0)
- [ ] Communication sent to stakeholders (see template in Step 7)
- [ ] Recovery commands reviewed and parameters populated with actual values

---

## Step 1: Assess the Incident (5 minutes)

### 1.1 Identify Affected Datasets

```bash
# Check BigQuery dataset health -- count rows in each staging table
bq query --use_legacy_sql=false \
  "SELECT table_id, row_count, size_bytes
   FROM staging.__TABLES__
   ORDER BY table_id"

# Check mart tables
bq query --use_legacy_sql=false \
  "SELECT table_id, row_count, size_bytes
   FROM marts_finance.__TABLES__
   ORDER BY table_id"

bq query --use_legacy_sql=false \
  "SELECT table_id, row_count, size_bytes
   FROM marts_analytics.__TABLES__
   ORDER BY table_id"
```

### 1.2 Determine Last Known Good State

```bash
# List available snapshots (most recent first)
bq ls --format=json fdp_prod_snapshots | jq '.[] | {tableId: .tableReference.tableId, creationTime: .creationTime}'

# Check the last successful pipeline run
bq query --use_legacy_sql=false \
  "SELECT dag_id, run_id, start_time, end_time, status
   FROM audit.pipeline_audit_log
   ORDER BY end_time DESC
   LIMIT 10"
```

### 1.3 Check GCS Backup State

```bash
# Compare object counts between raw and backup buckets
gsutil du -s gs://PROJECT_ID-financial-data-raw-prod/
gsutil du -s gs://PROJECT_ID-financial-data-backup-prod/

# Check last Storage Transfer job completion
gcloud transfer operations list --filter="transferSpec.gcsDataSource.bucketName=PROJECT_ID-financial-data-raw-prod" --limit=5
```

### 1.4 Notify

```bash
# Post to incident channel (replace with your notification mechanism)
echo "DR INITIATED: Financial Data Platform
Affected: [DATASETS]
Last known good: [SNAPSHOT_DATE]
Commander: [NAME]
ETA to recovery: 45 minutes"
```

---

## Step 2: Pause Active Processing (2 minutes)

### 2.1 Disable Airflow DAGs

```bash
# Disable the daily pipeline to prevent it from overwriting restored data
gcloud composer environments run prod-composer \
  --location=us-central1 \
  dags pause -- financial_pipeline_daily
```

### 2.2 Scale Down Ingestion Service

```bash
# Scale the ingestion service to 0 to stop writes
kubectl scale deployment ingestion-service --replicas=0 -n financial-data

# Verify no pods are running
kubectl get pods -n financial-data -l app=ingestion-service
```

### 2.3 Note Current Pub/Sub Position

```bash
# Record current subscription position for replay reference
gcloud pubsub subscriptions describe financial-events-validated-sub \
  --format="json(ackDeadlineSeconds, messageRetentionDuration, pushConfig)"
```

---

## Step 3: Restore BigQuery Data (15 minutes)

### 3.1 Restore from Dataset Snapshot

BigQuery snapshot restore is a metadata operation -- it completes in seconds regardless of data size.

```bash
# Set variables
SNAPSHOT_DATE="20260310"  # Replace with last known good date
PROJECT="your-project-id"
ENVIRONMENT="prod"

# Restore staging tables
for TABLE in stg_revenue_transactions stg_usage_metrics stg_cost_records; do
  echo "Restoring staging.${TABLE} from snapshot ${SNAPSHOT_DATE}..."
  bq cp --force \
    "fdp_${ENVIRONMENT}_snapshots.staging_snapshot_${SNAPSHOT_DATE}.${TABLE}" \
    "${PROJECT}:staging.${TABLE}"
done

# Restore mart tables
for TABLE in fct_daily_revenue_summary fct_monthly_cost_attribution fct_revenue_by_product_region; do
  echo "Restoring marts_finance.${TABLE} from snapshot ${SNAPSHOT_DATE}..."
  bq cp --force \
    "fdp_${ENVIRONMENT}_snapshots.marts_finance_snapshot_${SNAPSHOT_DATE}.${TABLE}" \
    "${PROJECT}:marts_finance.${TABLE}"
done

for TABLE in fct_customer_usage_report fct_unit_economics; do
  echo "Restoring marts_analytics.${TABLE} from snapshot ${SNAPSHOT_DATE}..."
  bq cp --force \
    "fdp_${ENVIRONMENT}_snapshots.marts_analytics_snapshot_${SNAPSHOT_DATE}.${TABLE}" \
    "${PROJECT}:marts_analytics.${TABLE}"
done
```

### 3.2 Alternative: Restore Using Time Travel

If the data was corrupted or deleted within the last 7 days, BigQuery time travel may be faster than snapshot restore.

```bash
# Restore a table to a specific point in time
RESTORE_TIMESTAMP="2026-03-10 02:00:00 UTC"

bq cp --force \
  "staging.stg_revenue_transactions@$(date -d "${RESTORE_TIMESTAMP}" +%s000)" \
  "staging.stg_revenue_transactions"
```

### 3.3 Verify Row Counts

```bash
# Compare restored data against pre-incident baselines
bq query --use_legacy_sql=false \
  "SELECT 'staging.stg_revenue_transactions' AS table_name, COUNT(*) AS row_count
   FROM staging.stg_revenue_transactions
   UNION ALL
   SELECT 'staging.stg_usage_metrics', COUNT(*)
   FROM staging.stg_usage_metrics
   UNION ALL
   SELECT 'staging.stg_cost_records', COUNT(*)
   FROM staging.stg_cost_records
   UNION ALL
   SELECT 'marts_finance.fct_daily_revenue_summary', COUNT(*)
   FROM marts_finance.fct_daily_revenue_summary"
```

---

## Step 4: Restore GCS Data (10 minutes)

Only required if GCS raw bucket data is affected.

### 4.1 Restore from Backup Bucket

```bash
# Full sync from backup to raw bucket (parallel, recursive)
gsutil -m rsync -r \
  gs://PROJECT_ID-financial-data-backup-prod/ \
  gs://PROJECT_ID-financial-data-raw-prod/

# Verify object counts match
echo "Raw bucket:"
gsutil ls -l gs://PROJECT_ID-financial-data-raw-prod/ | tail -1
echo "Backup bucket:"
gsutil ls -l gs://PROJECT_ID-financial-data-backup-prod/ | tail -1
```

### 4.2 Restore Specific Date Range

If only a subset of data is affected:

```bash
# Restore only files from a specific date prefix
gsutil -m rsync -r \
  gs://PROJECT_ID-financial-data-backup-prod/2026/03/10/ \
  gs://PROJECT_ID-financial-data-raw-prod/2026/03/10/
```

### 4.3 Restore from Object Versioning

If specific files were overwritten or deleted:

```bash
# List object versions
gsutil ls -la gs://PROJECT_ID-financial-data-raw-prod/path/to/file.json

# Restore a specific version
gsutil cp \
  "gs://PROJECT_ID-financial-data-raw-prod/path/to/file.json#VERSION_ID" \
  gs://PROJECT_ID-financial-data-raw-prod/path/to/file.json
```

---

## Step 5: Replay Pub/Sub Messages (10 minutes)

If events were lost between the last snapshot and the incident, replay from Pub/Sub.

### 5.1 Seek Subscription to Timestamp

```bash
# Seek to the last successfully processed timestamp
REPLAY_TIMESTAMP="2026-03-10T02:00:00Z"

gcloud pubsub subscriptions seek financial-events-validated-sub \
  --time="${REPLAY_TIMESTAMP}"
```

### 5.2 Monitor DLQ for Incident-Period Failures

```bash
# Check if any messages ended up in the DLQ during the incident
gcloud pubsub subscriptions pull financial-events-dead-letter-sub \
  --limit=10 \
  --auto-ack=false
```

### 5.3 Verify Message Processing

```bash
# Monitor subscription backlog as messages are reprocessed
watch -n 5 'gcloud pubsub subscriptions describe financial-events-validated-sub \
  --format="value(numUndeliveredMessages)"'
```

---

## Step 6: Validate Recovery (5 minutes)

### 6.1 Run dbt Tests

```bash
# Run the full dbt test suite against restored data
cd dbt_project && dbt test --profiles-dir . --target prod
```

### 6.2 Verify Data Quality

```bash
# Check for revenue non-negativity
bq query --use_legacy_sql=false \
  "SELECT COUNT(*) AS negative_revenue_rows
   FROM marts_finance.fct_daily_revenue_summary
   WHERE total_revenue_usd < 0"

# Check for date completeness (no gaps)
bq query --use_legacy_sql=false \
  "WITH date_range AS (
     SELECT MIN(revenue_date) AS min_date, MAX(revenue_date) AS max_date
     FROM marts_finance.fct_daily_revenue_summary
   )
   SELECT DATE_DIFF(max_date, min_date, DAY) + 1 AS expected_days,
          COUNT(DISTINCT revenue_date) AS actual_days
   FROM marts_finance.fct_daily_revenue_summary, date_range"

# Check referential integrity
bq query --use_legacy_sql=false \
  "SELECT COUNT(*) AS orphan_usage_records
   FROM staging.stg_usage_metrics u
   LEFT JOIN staging.stg_revenue_transactions r ON u.customer_id = r.customer_id
   WHERE r.customer_id IS NULL"
```

### 6.3 Resume Services

```bash
# Scale ingestion service back up
kubectl scale deployment ingestion-service --replicas=2 -n financial-data

# Verify health check passes
kubectl exec -it deployment/ingestion-service -n financial-data -- wget -qO- http://localhost:8080/healthz

# Unpause Airflow DAG
gcloud composer environments run prod-composer \
  --location=us-central1 \
  dags unpause -- financial_pipeline_daily

# Trigger a manual DAG run to process any data accumulated during the outage
gcloud composer environments run prod-composer \
  --location=us-central1 \
  dags trigger -- financial_pipeline_daily
```

---

## Step 7: Communication Template

### Incident Start

```
Subject: [INCIDENT] Financial Data Platform - Data Recovery In Progress

Team,

We have identified [data loss / corruption / region failure] affecting [AFFECTED DATASETS]
in the Financial Data Platform.

Impact:
- [Financial reporting data may be stale until recovery completes]
- [Access to [DATASETS] may return inconsistent results]

Timeline:
- [TIME] - Issue detected via [alert / manual observation]
- [TIME] - DR procedure initiated
- Estimated recovery: [TIME + 45 minutes]

Actions:
- Airflow DAGs paused
- Ingestion service scaled down
- Restoring from [snapshot / backup] dated [DATE]

Next update: [TIME + 30 minutes]

Incident Commander: [NAME]
```

### Incident Resolved

```
Subject: [RESOLVED] Financial Data Platform - Data Recovery Complete

Team,

The Financial Data Platform has been fully recovered.

Timeline:
- [TIME] - Issue detected
- [TIME] - DR procedure initiated
- [TIME] - Data restored from [snapshot / backup] dated [DATE]
- [TIME] - dbt tests passed, services resumed
- [TIME] - Recovery validated

Data impact:
- RPO achieved: [ACTUAL RPO] (target: <1 hour)
- RTO achieved: [ACTUAL RTO] (target: <45 minutes)
- Records recovered: [COUNT]
- Data gap (if any): [START] to [END]

Root cause: [BRIEF DESCRIPTION]

Post-incident review scheduled: [DATE/TIME]
```

---

## Step 8: Post-Incident Review Checklist

Complete within 48 hours of recovery:

- [ ] **Timeline documented**: Exact times for detection, decision, execution, and verification
- [ ] **Root cause identified**: What caused the data loss/corruption
- [ ] **RPO/RTO actual vs target**: Did we meet our recovery targets?
- [ ] **Data gap assessment**: Was any data permanently lost? If so, what is the impact?
- [ ] **Snapshot integrity**: Are all snapshots from the incident period valid?
- [ ] **Alert effectiveness**: Did monitoring detect the issue, or was it found manually?
- [ ] **Runbook accuracy**: Did the runbook steps work as documented? What needs updating?
- [ ] **Prevention measures**: What changes prevent recurrence?
- [ ] **Action items assigned**: Each improvement has an owner and due date
- [ ] **Post-incident review meeting held**: All relevant stakeholders attended
- [ ] **Audit log updated**: Incident and recovery details recorded in `audit.pipeline_audit_log`

---

## DR Architecture Reference

| Component | Backup Mechanism | RPO | Restore Time |
|-----------|-----------------|-----|-------------|
| BigQuery datasets | Daily snapshots (Data Transfer Service) | <24 hours | <1 minute (metadata operation) |
| BigQuery tables | Time travel (7-day window) | Point-in-time | <1 minute |
| GCS raw bucket | Cross-region replication (daily 03:00 UTC) | <24 hours | ~10 minutes (depends on size) |
| GCS objects | Object versioning | Point-in-time | <1 minute per object |
| Pub/Sub messages | 7-day message retention | Point-in-time | <1 minute (subscription seek) |
| BigTable data | Replicated from Pub/Sub (rebuild from source) | <1 hour | ~30 minutes (replay events) |
| Airflow DAGs | Git repository (source of truth) | Point-in-time | <5 minutes (git pull + deploy) |
| dbt models | Git repository (source of truth) | Point-in-time | <5 minutes (git pull + dbt run) |
| Terraform state | GCS backend with versioning | Point-in-time | <5 minutes |
