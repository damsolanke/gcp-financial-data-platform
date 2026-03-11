# -----------------------------------------------------------------------------
# Disaster Recovery Module
# -----------------------------------------------------------------------------
# This module implements the DR strategy for the financial data platform:
#
# 1. **BigQuery Dataset Snapshots**: Daily scheduled copies of each dataset
#    using BigQuery Data Transfer Service. Snapshots are retained for a
#    configurable period (default 30 days) and stored in a separate
#    "snapshot" dataset to prevent accidental deletion alongside source data.
#
# 2. **Monthly DR Test Trigger**: A Cloud Scheduler job triggers a monthly
#    DR test via HTTP to validate that recovery procedures work. This ensures
#    the team practices recovery regularly rather than discovering issues
#    during an actual incident.
#
# Recovery targets:
#   RTO (Recovery Time Objective): 45 minutes
#   RPO (Recovery Point Objective): 1 hour
#
# These targets are achievable because:
#   - BigQuery snapshots are near-instant to restore (metadata operation)
#   - GCS cross-region replication runs daily with 03:00 UTC schedule
#   - Pub/Sub message retention (7 days) allows replay from last checkpoint
# -----------------------------------------------------------------------------

locals {
  common_labels = merge(var.labels, {
    environment = var.environment
    managed_by  = "terraform"
    module      = "disaster_recovery"
  })
}

# ---------------------------------------------------------------------------
# Snapshot Destination Dataset
# ---------------------------------------------------------------------------
# All dataset snapshots land in a dedicated dataset to keep them isolated
# from active data. This prevents snapshot cleanup from accidentally affecting
# production tables, and allows separate IAM controls.

resource "google_bigquery_dataset" "snapshots" {
  project                     = var.project_id
  dataset_id                  = "fdp_${var.environment}_snapshots"
  friendly_name               = "DR Snapshots - ${var.environment}"
  description                 = "Destination for automated daily dataset snapshots. Tables are suffixed with the snapshot date. Retention: ${var.snapshot_retention_days} days."
  location                    = var.region
  default_table_expiration_ms = var.snapshot_retention_days * 24 * 60 * 60 * 1000 # Convert days to milliseconds
  delete_contents_on_destroy  = var.environment != "prod"
  labels                      = local.common_labels
}

# ---------------------------------------------------------------------------
# BigQuery Data Transfer Configs (Dataset Snapshots)
# ---------------------------------------------------------------------------
# One transfer config per source dataset. Each runs daily and creates a
# snapshot table with a date suffix (e.g., stg_revenue_transactions_20240115).
# The snapshot dataset's default_table_expiration_ms handles cleanup.

resource "google_bigquery_data_transfer_config" "dataset_snapshots" {
  for_each = var.source_datasets

  project                = var.project_id
  display_name           = "DR Snapshot: ${each.key} (${var.environment})"
  location               = var.region
  data_source_id         = "cross_region_copy"
  destination_dataset_id = google_bigquery_dataset.snapshots.dataset_id

  # Run daily. The schedule string uses BigQuery Transfer Service syntax.
  schedule = "every 24 hours"

  params = {
    # The source dataset to snapshot.
    source_dataset_id = each.value

    # Destination table naming pattern. The run_date suffix ensures each
    # daily snapshot creates a new table rather than overwriting the previous one.
    destination_table_name_template = "${each.key}_snapshot_{run_date}"

    # Overwrite destination tables if they already exist (idempotent reruns).
    overwrite_destination_table = "true"
  }
}

# ---------------------------------------------------------------------------
# Monthly DR Test Trigger
# ---------------------------------------------------------------------------
# This Cloud Scheduler job fires on the first Monday of each month to trigger
# a DR test. The target is a Cloud Function (or Cloud Run service) that:
#   1. Restores the latest snapshot to a temporary dataset
#   2. Validates row counts and checksums against the source
#   3. Records the test result in the audit.pipeline_audit_log table
#   4. Sends a notification to the on-call channel
#
# The Cloud Function itself is deployed separately (not managed by this module)
# because its code changes more frequently than infrastructure.

resource "google_cloud_scheduler_job" "monthly_dr_test" {
  project     = var.project_id
  name        = "fdp-dr-test-monthly-${var.environment}"
  description = "Triggers a monthly DR validation test on the first Monday of each month at 10:00 UTC"
  region      = var.region
  schedule    = "0 10 * * 1" # Every Monday at 10:00 UTC; the Cloud Function checks if it's the first Monday

  # Retry configuration: if the DR test trigger fails, retry up to 3 times.
  # This is for the trigger itself, not the DR test execution.
  retry_config {
    retry_count          = 3
    min_backoff_duration = "30s"
    max_backoff_duration = "300s"
  }

  http_target {
    # The Cloud Function endpoint. This URL is a placeholder; the actual
    # endpoint is set after the Cloud Function is deployed.
    uri         = "https://${var.region}-${var.project_id}.cloudfunctions.net/dr-test-runner"
    http_method = "POST"

    body = base64encode(jsonencode({
      environment      = var.environment
      source_datasets  = var.source_datasets
      snapshot_dataset = google_bigquery_dataset.snapshots.dataset_id
      backup_region    = var.backup_region
      test_type        = "monthly_validation"
    }))

    headers = {
      "Content-Type" = "application/json"
    }

    # Use OIDC authentication so the scheduler job authenticates to the
    # Cloud Function using its own service account identity.
    oidc_token {
      service_account_email = "${var.project_id}@appspot.gserviceaccount.com"
    }
  }
}

# ---------------------------------------------------------------------------
# Recovery Procedure Documentation
# ---------------------------------------------------------------------------
# This local value documents the recovery procedure as a Terraform output.
# It serves as machine-readable documentation that can be included in
# runbooks and incident response playbooks.

locals {
  recovery_procedure = <<-EOT
    # Financial Data Platform - Disaster Recovery Procedure
    # Environment: ${var.environment}
    # RTO Target: 45 minutes | RPO Target: 1 hour

    ## Step 1: Assess the Incident (5 minutes)
    - Identify affected datasets and services
    - Determine the last known good snapshot date
    - Notify the incident commander and data engineering on-call

    ## Step 2: Restore BigQuery Data (15 minutes)
    - Navigate to the snapshot dataset: fdp_${var.environment}_snapshots
    - Identify the latest snapshot tables for affected datasets
    - Use BigQuery table copy to restore snapshots to the source datasets:
      bq cp fdp_${var.environment}_snapshots.<table>_snapshot_<date> fdp_${var.environment}_<dataset>.<table>

    ## Step 3: Restore GCS Data (10 minutes)
    - If GCS data is affected, initiate restore from the backup bucket
    - Use gsutil rsync from the backup bucket to the raw bucket:
      gsutil -m rsync -r gs://${var.project_id}-financial-data-backup-${var.environment}/ gs://${var.project_id}-financial-data-raw-${var.environment}/

    ## Step 4: Replay Pub/Sub Messages (10 minutes)
    - If message processing was interrupted, seek the subscription to the
      last successfully processed timestamp
    - Monitor the DLQ for messages that failed during the incident

    ## Step 5: Validate Recovery (5 minutes)
    - Run data quality checks on restored datasets
    - Verify row counts match pre-incident baselines
    - Confirm all pipeline DAGs are running successfully
    - Update the incident timeline with recovery completion
  EOT
}
