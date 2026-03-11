# -----------------------------------------------------------------------------
# IAM Module
# -----------------------------------------------------------------------------
# This module implements the principle of least privilege for the financial
# data platform. Each service gets its own service account with only the
# permissions it needs:
#
#   ingestion-sa  : publishes to Pub/Sub, reads/writes Bigtable
#   governance-sa : reads audit data, runs BigQuery jobs for compliance
#   airflow-sa    : orchestrates pipelines, reads GCS, writes BigQuery
#   dbt-sa        : transforms data across staging/intermediate/marts
#
# Dataset-level IAM is used for BigQuery because it's the narrowest scope
# that doesn't require per-table bindings (which don't scale well with
# Terraform when tables are managed by dbt).
#
# A custom role (financial_auditor) restricts audit access to read-only
# on audit tables, preventing accidental writes to the immutable audit log.
# -----------------------------------------------------------------------------

locals {
  # Service account naming convention: {function}-sa-{environment}
  # The environment suffix prevents cross-environment privilege escalation
  # in projects that share a GCP project (common in dev/staging).
  sa_prefix = "fdp-${var.environment}"
}

# ---------------------------------------------------------------------------
# Service Accounts
# ---------------------------------------------------------------------------

# Ingestion service account: used by the GKE-based ingestion service to
# publish validated events to Pub/Sub and write raw lookups to Bigtable.
resource "google_service_account" "ingestion" {
  project      = var.project_id
  account_id   = "${local.sa_prefix}-ingestion-sa"
  display_name = "Ingestion Service Account (${var.environment})"
  description  = "Used by the ingestion service to publish to Pub/Sub and write to Bigtable. Runs on GKE with Workload Identity."
}

# Governance service account: used by compliance and audit tooling to read
# audit logs and run analytical queries against audit data.
resource "google_service_account" "governance" {
  project      = var.project_id
  account_id   = "${local.sa_prefix}-governance-sa"
  display_name = "Governance Service Account (${var.environment})"
  description  = "Used by governance and compliance services for read-only access to audit data and BigQuery job execution."
}

# Airflow service account: used by Cloud Composer to orchestrate data
# pipelines, read from GCS, and write to BigQuery.
resource "google_service_account" "airflow" {
  project      = var.project_id
  account_id   = "${local.sa_prefix}-airflow-sa"
  display_name = "Airflow Service Account (${var.environment})"
  description  = "Used by Cloud Composer to orchestrate data pipelines. Needs GCS read, BigQuery write, and Composer worker permissions."
}

# dbt service account: used by dbt to transform data across the BigQuery
# dataset layers (staging -> intermediate -> marts).
resource "google_service_account" "dbt" {
  project      = var.project_id
  account_id   = "${local.sa_prefix}-dbt-sa"
  display_name = "dbt Service Account (${var.environment})"
  description  = "Used by dbt for data transformations across BigQuery datasets. Has editor access on staging, intermediate, and mart datasets."
}

# ---------------------------------------------------------------------------
# Project-Level IAM Bindings
# ---------------------------------------------------------------------------
# These bindings grant permissions that cannot be scoped to a single resource
# (e.g., Pub/Sub publisher is project-wide because the ingestion service
# may need to publish to multiple topics).

# Ingestion SA needs to publish validated events to Pub/Sub topics.
resource "google_project_iam_member" "ingestion_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.ingestion.email}"
}

# Ingestion SA needs to read/write Bigtable for event deduplication and
# low-latency lookups.
resource "google_project_iam_member" "ingestion_bigtable_user" {
  project = var.project_id
  role    = "roles/bigtable.user"
  member  = "serviceAccount:${google_service_account.ingestion.email}"
}

# Governance SA needs to run BigQuery jobs to execute audit queries.
# jobUser is project-level because jobs aren't scoped to datasets.
resource "google_project_iam_member" "governance_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.governance.email}"
}

# Airflow SA needs Composer worker permissions to run Airflow tasks.
resource "google_project_iam_member" "airflow_composer_worker" {
  project = var.project_id
  role    = "roles/composer.worker"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

# Airflow SA needs to read objects from GCS (raw bucket, DAG bucket).
resource "google_project_iam_member" "airflow_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.airflow.email}"
}

# dbt SA needs to run BigQuery jobs for transformations.
resource "google_project_iam_member" "dbt_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dbt.email}"
}

# ---------------------------------------------------------------------------
# Dataset-Level IAM Bindings
# ---------------------------------------------------------------------------
# Dataset-level bindings are preferred over project-level for BigQuery data
# access because they limit blast radius — a compromised dbt SA cannot read
# audit data, and a compromised governance SA cannot modify staging data.

# Governance SA: read-only access to audit dataset only.
resource "google_bigquery_dataset_iam_member" "governance_audit_viewer" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["audit"]
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.governance.email}"
}

# Airflow SA: editor access to all datasets because Airflow orchestrates
# both ingestion (writes to staging) and dbt runs (writes to all layers).
resource "google_bigquery_dataset_iam_member" "airflow_staging_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["staging"]
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_bigquery_dataset_iam_member" "airflow_intermediate_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["intermediate"]
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_bigquery_dataset_iam_member" "airflow_marts_finance_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["marts_finance"]
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}

resource "google_bigquery_dataset_iam_member" "airflow_marts_analytics_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["marts_analytics"]
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.airflow.email}"
}

# dbt SA: editor access to staging, intermediate, and mart datasets.
# dbt needs to create/replace tables and views in these datasets.
resource "google_bigquery_dataset_iam_member" "dbt_staging_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["staging"]
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dbt.email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_intermediate_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["intermediate"]
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dbt.email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_marts_finance_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["marts_finance"]
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dbt.email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_marts_analytics_editor" {
  project    = var.project_id
  dataset_id = var.bigquery_datasets["marts_analytics"]
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.dbt.email}"
}

# ---------------------------------------------------------------------------
# Custom Role: Financial Auditor
# ---------------------------------------------------------------------------
# This role grants the minimum permissions needed to run read-only queries
# against audit tables. It's intentionally restrictive: no ability to modify
# data, create tables, or access non-audit datasets. Used by compliance
# officers and external auditors.

resource "google_project_iam_custom_role" "financial_auditor" {
  project     = var.project_id
  role_id     = "financial_auditor_${var.environment}"
  title       = "Financial Auditor (${var.environment})"
  description = "Read-only access to audit tables for compliance officers and external auditors. Cannot modify data or access non-audit datasets."

  permissions = [
    "bigquery.datasets.get",   # Required to list and describe audit dataset metadata
    "bigquery.tables.get",     # Required to describe audit table schemas
    "bigquery.tables.getData", # Required to read audit table contents
    "bigquery.jobs.create",    # Required to execute queries (BigQuery requires a job for every query)
  ]

  # ALPHA stage means this role is subject to change. Promote to BETA/GA
  # after the permission set is validated with the compliance team.
  stage = "GA"
}

# ---------------------------------------------------------------------------
# Workload Identity Bindings
# ---------------------------------------------------------------------------
# Workload Identity allows GKE pods to impersonate GCP service accounts
# without needing to manage JSON key files. This is the recommended approach
# for GKE workloads because it eliminates key rotation burden and reduces
# the blast radius of a compromised pod.

# Allow the ingestion Kubernetes service account to act as the ingestion
# GCP service account. The KSA name follows the convention:
# {namespace}/{ksa-name} = data-services/ingestion-service
resource "google_service_account_iam_member" "ingestion_workload_identity" {
  service_account_id = google_service_account.ingestion.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[data-services/ingestion-service]"
}

# Allow the governance Kubernetes service account to act as the governance
# GCP service account.
resource "google_service_account_iam_member" "governance_workload_identity" {
  service_account_id = google_service_account.governance.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[data-services/governance-service]"
}
