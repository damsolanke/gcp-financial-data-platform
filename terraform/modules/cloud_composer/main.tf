# -----------------------------------------------------------------------------
# Cloud Composer Module
# -----------------------------------------------------------------------------
# Cloud Composer (managed Apache Airflow) orchestrates the data platform's
# batch processing pipelines:
#   - dbt model runs (staging -> intermediate -> marts)
#   - GCS file ingestion triggers
#   - BigQuery maintenance (partition pruning, table snapshots)
#   - Data quality checks and anomaly detection
#
# Composer 2 is used because:
#   1. Autoscaling workers based on task queue depth
#   2. Lower base cost (pay per task, not per idle worker)
#   3. Better integration with GKE Autopilot
#   4. Faster environment creation and update times
# -----------------------------------------------------------------------------

locals {
  common_labels = merge(var.labels, {
    environment = var.environment
    managed_by  = "terraform"
    module      = "cloud_composer"
  })

  # Environment sizing: dev uses minimal resources to reduce cost, prod
  # uses medium resources to handle concurrent DAG runs during peak hours.
  is_prod = var.environment == "prod"
}

resource "google_composer_environment" "main" {
  project = var.project_id
  name    = "fdp-composer-${var.environment}"
  region  = var.region
  labels  = local.common_labels

  config {
    # Environment size controls the Composer infrastructure (metadata DB,
    # web server capacity, etc.). SMALL is sufficient for dev with <50 DAGs;
    # MEDIUM handles prod workloads with 50-200 DAGs.
    environment_size = local.is_prod ? "ENVIRONMENT_SIZE_MEDIUM" : "ENVIRONMENT_SIZE_SMALL"

    software_config {
      # Pin to a specific Composer 2 + Airflow 2 image version for
      # reproducibility. Update this deliberately, not automatically.
      image_version = "composer-2-airflow-2"

      # PyPI packages needed by DAGs. Version constraints ensure compatibility
      # with the Composer image while allowing patch updates.
      pypi_packages = {
        dbt-bigquery          = ">=1.7"
        google-cloud-bigquery = ">=3.0"
        pandas                = ">=2.0"
        scipy                 = ">=1.11"
      }

      # Environment variables available to all DAGs. These avoid hardcoding
      # project and dataset references in DAG code.
      env_variables = {
        GCP_PROJECT_ID             = var.project_id
        ENVIRONMENT                = var.environment
        BQ_DATASET_STAGING         = "fdp_${var.environment}_staging"
        BQ_DATASET_INTERMEDIATE    = "fdp_${var.environment}_intermediate"
        BQ_DATASET_MARTS_FINANCE   = "fdp_${var.environment}_marts_finance"
        BQ_DATASET_MARTS_ANALYTICS = "fdp_${var.environment}_marts_analytics"
        BQ_DATASET_AUDIT           = "fdp_${var.environment}_audit"
      }
    }

    # Workload configuration controls CPU/memory for Composer components.
    # These are sized based on observed resource usage in similar deployments.
    workloads_config {
      scheduler {
        cpu        = local.is_prod ? 2 : 0.5
        memory_gb  = local.is_prod ? 4 : 1
        storage_gb = local.is_prod ? 2 : 1
        count      = local.is_prod ? 2 : 1 # Two schedulers for HA in prod
      }

      web_server {
        cpu        = local.is_prod ? 2 : 0.5
        memory_gb  = local.is_prod ? 4 : 1
        storage_gb = local.is_prod ? 2 : 1
      }

      worker {
        cpu        = local.is_prod ? 2 : 0.5
        memory_gb  = local.is_prod ? 4 : 1
        storage_gb = local.is_prod ? 2 : 1
        min_count  = local.is_prod ? 2 : 1
        max_count  = local.is_prod ? 8 : 3
      }
    }

    node_config {
      service_account = var.service_account_email
      network         = var.network_id
      subnetwork      = var.subnet_id
    }

    # Maintenance window: weekdays 02:00-06:00 UTC. This avoids the primary
    # batch processing window (06:00-22:00 UTC) and weekend on-call coverage.
    # The 4-hour window gives GCP enough time to apply updates without
    # disrupting active DAG runs.
    maintenance_window {
      start_time = "2024-01-01T02:00:00Z"
      end_time   = "2024-01-01T06:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
    }
  }
}
