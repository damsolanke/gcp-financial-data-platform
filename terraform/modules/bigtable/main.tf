# -----------------------------------------------------------------------------
# Bigtable Module
# -----------------------------------------------------------------------------
# Bigtable serves as the low-latency lookup layer for the financial data
# platform. While BigQuery handles analytical queries, Bigtable handles
# point-reads and range-scans for real-time services that need sub-10ms
# access to recent financial events (e.g., fraud detection, duplicate
# detection, real-time dashboards).
#
# Row key design: {customer_id}#{reverse_timestamp}#{event_type}
# This enables efficient scans of recent events per customer while
# distributing writes across regions of the keyspace.
# -----------------------------------------------------------------------------

locals {
  common_labels = merge(var.labels, {
    environment = var.environment
    managed_by  = "terraform"
    module      = "bigtable"
  })
}

# The instance is the top-level container. We use PRODUCTION type for all
# environments because DEVELOPMENT instances cannot be resized and lack
# replication support, making them unsuitable even for staging validation.
resource "google_bigtable_instance" "financial_events" {
  project      = var.project_id
  name         = "${var.instance_name}-${var.environment}"
  display_name = "Financial Events (${var.environment})"
  labels       = local.common_labels

  # Prevent accidental deletion in production. Terraform will refuse to
  # destroy the instance unless this is toggled off first.
  deletion_protection = var.environment == "prod" ? true : false

  cluster {
    cluster_id   = "${var.instance_name}-${var.environment}-cluster"
    zone         = var.zone
    num_nodes    = var.num_nodes
    storage_type = var.storage_type
  }
}

# The primary table stores all financial events. Column families are designed
# around access patterns rather than data type, because Bigtable GC policies
# and read performance are per-column-family.
resource "google_bigtable_table" "financial_events" {
  project       = var.project_id
  instance_name = google_bigtable_instance.financial_events.name
  name          = "financial_events"

  # event_data: the primary payload columns (amount, currency, metadata, etc.)
  # Retained for 90 days because real-time services rarely need older data;
  # historical queries go to BigQuery instead.
  column_family {
    family = "event_data"
  }

  # metadata: ingestion lineage (source_system, ingestion_timestamp, etc.)
  # Only the latest version is kept because metadata is overwritten on
  # re-processing, not appended.
  column_family {
    family = "metadata"
  }

  # processing_status: tracks whether the event has been validated, enriched,
  # and loaded into BigQuery. Three versions retained so the ingestion service
  # can inspect the processing history for debugging failed events.
  column_family {
    family = "processing_status"
  }
}

# GC policy for event_data: drop cells older than 90 days.
# This keeps the table lean for point-read workloads while older data is
# already archived in BigQuery via the ingestion pipeline.
resource "google_bigtable_gc_policy" "event_data_gc" {
  project       = var.project_id
  instance_name = google_bigtable_instance.financial_events.name
  table         = google_bigtable_table.financial_events.name
  column_family = "event_data"

  max_age {
    duration = "2160h" # 90 days = 90 * 24h
  }
}

# GC policy for metadata: keep only the latest version.
# Metadata is idempotently overwritten, so older versions are redundant.
resource "google_bigtable_gc_policy" "metadata_gc" {
  project       = var.project_id
  instance_name = google_bigtable_instance.financial_events.name
  table         = google_bigtable_table.financial_events.name
  column_family = "metadata"

  max_version {
    number = 1
  }
}

# GC policy for processing_status: keep last 3 versions.
# Allows the ingestion service to inspect the processing history
# (e.g., validated -> enrichment_failed -> enriched) for debugging.
resource "google_bigtable_gc_policy" "processing_status_gc" {
  project       = var.project_id
  instance_name = google_bigtable_instance.financial_events.name
  table         = google_bigtable_table.financial_events.name
  column_family = "processing_status"

  max_version {
    number = 3
  }
}

# App profile for single-row transactions. The ingestion service uses
# check-and-mutate operations for deduplication (write only if the
# surrogate_key doesn't already exist). Single-cluster routing is required
# for strong consistency in these transactions.
resource "google_bigtable_app_profile" "single_row_transactions" {
  project        = var.project_id
  instance       = google_bigtable_instance.financial_events.name
  app_profile_id = "single-row-txns"
  description    = "Profile for single-row check-and-mutate operations used by the ingestion service for deduplication"

  # Single-cluster routing ensures strong consistency for transactional reads.
  # Multi-cluster routing would risk stale reads during deduplication checks.
  single_cluster_routing {
    cluster_id                 = "${var.instance_name}-${var.environment}-cluster"
    allow_transactional_writes = true
  }

  # Ignore warnings about single-cluster routing reducing availability.
  # For deduplication, consistency is more important than availability.
  ignore_warnings = true
}
