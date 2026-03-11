# -----------------------------------------------------------------------------
# GCS Module
# -----------------------------------------------------------------------------
# Cloud Storage provides the durable, cost-effective storage layer for:
#   1. Raw financial data files (CSV, Parquet, JSON) before ingestion
#   2. Long-term backups with automated lifecycle transitions
#   3. Event-driven ingestion triggers via Pub/Sub notifications
#
# Two-bucket architecture:
#   - Raw bucket (multi-region US): high availability for active ingestion
#   - Backup bucket (single region): cost-optimized with lifecycle tiering
#     for 7-year retention (SOX/GDPR compliance)
#
# Cross-region replication via Storage Transfer ensures the backup bucket
# stays current even if the primary region experiences a sustained outage.
# -----------------------------------------------------------------------------

locals {
  common_labels = merge(var.labels, {
    environment = var.environment
    managed_by  = "terraform"
    module      = "gcs"
  })
}

# ---------------------------------------------------------------------------
# Raw Data Bucket
# ---------------------------------------------------------------------------
# Multi-region "US" for maximum availability during ingestion. Financial data
# files land here from external sources (SFTP, partner APIs, manual uploads)
# before the ingestion pipeline picks them up.

resource "google_storage_bucket" "raw" {
  project  = var.project_id
  name     = "${var.project_id}-financial-data-raw-${var.environment}"
  location = "US"
  labels   = local.common_labels

  # Uniform bucket-level access simplifies IAM management and is required
  # for organization policy compliance. ACLs are disabled.
  uniform_bucket_level_access = true

  # Versioning protects against accidental overwrites or deletions of raw data.
  # The ingestion pipeline is idempotent, but source systems may re-upload
  # corrected files with the same name.
  versioning {
    enabled = true
  }

  # Force destroy only in non-prod to allow quick iteration.
  # In prod, manual intervention is required to delete a bucket with data.
  force_destroy = var.environment != "prod"
}

# ---------------------------------------------------------------------------
# Backup Bucket
# ---------------------------------------------------------------------------
# Regional bucket with aggressive lifecycle tiering to minimise storage costs
# while meeting the 7-year retention requirement for financial records.
# The tiering schedule: STANDARD -> NEARLINE (30d) -> COLDLINE (90d) ->
# ARCHIVE (365d) -> DELETE (2555d / ~7 years).

resource "google_storage_bucket" "backup" {
  project  = var.project_id
  name     = "${var.project_id}-financial-data-backup-${var.environment}"
  location = var.backup_region
  labels   = local.common_labels

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  force_destroy = var.environment != "prod"

  # Transition to Nearline after 30 days. Data accessed less than once per
  # month costs less in Nearline than Standard.
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  # Transition to Coldline after 90 days. Quarterly financial reviews may
  # still need this data, but daily access is unlikely.
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  # Transition to Archive after 1 year. Only needed for audits and legal holds.
  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }

  # Delete after 7 years (2555 days). Aligns with SOX record retention
  # requirements. For GDPR, data subject deletion requests are handled
  # separately at the object level.
  lifecycle_rule {
    condition {
      age = 2555
    }
    action {
      type = "Delete"
    }
  }
}

# ---------------------------------------------------------------------------
# Cross-Region Replication (Storage Transfer)
# ---------------------------------------------------------------------------
# Daily transfer job copies new/changed objects from the raw bucket to the
# backup bucket. Scheduled at 03:00 UTC to avoid contention with the peak
# ingestion window (typically 08:00-18:00 UTC).

resource "google_storage_transfer_job" "raw_to_backup" {
  project     = var.project_id
  description = "Daily cross-region replication of raw financial data to backup bucket (${var.environment})"

  transfer_spec {
    gcs_data_source {
      bucket_name = google_storage_bucket.raw.name
    }
    gcs_data_sink {
      bucket_name = google_storage_bucket.backup.name
    }

    # Only transfer objects that have been modified since the last transfer.
    # This avoids re-copying the entire bucket on every run.
    transfer_options {
      overwrite_objects_already_existing_in_sink = false
      delete_objects_from_source_after_transfer  = false
    }
  }

  schedule {
    schedule_start_date {
      year  = 2024
      month = 1
      day   = 1
    }

    # 03:00 UTC avoids peak ingestion hours and gives the raw bucket time
    # to accumulate the previous day's uploads before replication begins.
    start_time_of_day {
      hours   = 3
      minutes = 0
      seconds = 0
      nanos   = 0
    }

    # Repeat daily with no end date — replication should run indefinitely.
    repeat_interval = "86400s"
  }
}

# ---------------------------------------------------------------------------
# Pub/Sub Notification on Raw Bucket
# ---------------------------------------------------------------------------
# Object finalize notifications trigger the event-driven ingestion pipeline.
# When a new file lands in the raw bucket, a Pub/Sub message is published
# with the object metadata, which the ingestion service consumes to start
# processing. This eliminates polling and reduces ingestion latency.

# Topic for GCS notifications. Separate from the validated events topic
# because raw file arrival and validated event processing are different
# concerns with different subscribers.
resource "google_pubsub_topic" "gcs_notifications" {
  project = var.project_id
  name    = "gcs-raw-file-notifications-${var.environment}"
  labels  = local.common_labels
}

# GCS notification configuration. Only triggers on OBJECT_FINALIZE (new
# object created or existing object overwritten) — we don't need notifications
# for deletions or metadata updates.
resource "google_storage_notification" "raw_bucket_notification" {
  bucket         = google_storage_bucket.raw.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.gcs_notifications.id
  event_types    = ["OBJECT_FINALIZE"]

  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# Grant the GCS service account permission to publish to the notification topic.
# Without this, GCS cannot deliver notifications and they fail silently.
data "google_storage_project_service_account" "gcs_sa" {
  project = var.project_id
}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.gcs_notifications.id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}
