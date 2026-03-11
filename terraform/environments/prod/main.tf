# -----------------------------------------------------------------------------
# Production Environment
# -----------------------------------------------------------------------------
# This is the production environment root module. It wires together all
# platform modules with production-grade settings:
#   - Deletion protection enabled on all stateful resources
#   - Higher node counts and replica counts for throughput and availability
#   - Medium Composer environment with HA scheduler
#   - GCS backend with state locking for safe concurrent operations
#   - 30-day snapshot retention for disaster recovery
#
# To apply: cd terraform/environments/prod && terraform init && terraform apply
# IMPORTANT: Always run terraform plan first and review the diff carefully.
# -----------------------------------------------------------------------------

terraform {
  # GCS backend provides state locking and versioning for production.
  # The state bucket must exist before terraform init. Create it manually
  # or via a bootstrap script to avoid the chicken-and-egg problem.
  backend "gcs" {
    bucket = "your-prod-project-id-terraform-state"
    prefix = "financial-data-platform/prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# The Kubernetes provider authenticates to the GKE cluster using the
# Google Cloud SDK credentials and the cluster's CA certificate.
provider "kubernetes" {
  host                   = "https://${module.kubernetes.cluster_endpoint}"
  cluster_ca_certificate = base64decode(module.kubernetes.cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

data "google_client_config" "default" {}

locals {
  environment = "prod"

  common_labels = {
    environment = "prod"
    project     = "financial-data-platform"
    managed_by  = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Module: BigQuery
# ---------------------------------------------------------------------------
module "bigquery" {
  source = "../../modules/bigquery"

  project_id          = var.project_id
  region              = var.region
  environment         = local.environment
  deletion_protection = true # Prod: prevent accidental deletion of datasets and tables
  labels              = local.common_labels
}

# ---------------------------------------------------------------------------
# Module: Bigtable
# ---------------------------------------------------------------------------
module "bigtable" {
  source = "../../modules/bigtable"

  project_id    = var.project_id
  zone          = "${var.region}-a"
  instance_name = "financial-events"
  environment   = local.environment
  num_nodes     = 3 # Prod: 3 nodes for throughput and availability during node maintenance
  storage_type  = "SSD"
  labels        = local.common_labels
}

# ---------------------------------------------------------------------------
# Module: Pub/Sub
# ---------------------------------------------------------------------------
module "pubsub" {
  source = "../../modules/pubsub"

  project_id                 = var.project_id
  environment                = local.environment
  message_retention_duration = "604800s"  # 7 days — covers extended weekend outages
  dlq_retention              = "2592000s" # 30 days — allows thorough investigation
  labels                     = local.common_labels
}

# ---------------------------------------------------------------------------
# Module: GCS
# ---------------------------------------------------------------------------
module "gcs" {
  source = "../../modules/gcs"

  project_id    = var.project_id
  region        = var.region
  backup_region = "us-east1"
  environment   = local.environment
  labels        = local.common_labels
}

# ---------------------------------------------------------------------------
# Module: IAM
# ---------------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  project_id        = var.project_id
  environment       = local.environment
  bigquery_datasets = module.bigquery.dataset_ids
  labels            = local.common_labels
}

# ---------------------------------------------------------------------------
# Module: Kubernetes (GKE)
# ---------------------------------------------------------------------------
module "kubernetes" {
  source = "../../modules/kubernetes"

  project_id          = var.project_id
  region              = var.region
  environment         = local.environment
  network_id          = "default" # Replace with actual VPC network self_link in production
  subnet_id           = "default" # Replace with actual subnet self_link in production
  ingestion_sa_email  = module.iam.service_account_emails["ingestion"]
  governance_sa_email = module.iam.service_account_emails["governance"]
  labels              = local.common_labels
}

# ---------------------------------------------------------------------------
# Module: Cloud Composer
# ---------------------------------------------------------------------------
module "cloud_composer" {
  source = "../../modules/cloud_composer"

  project_id            = var.project_id
  region                = var.region
  environment           = local.environment # "prod" triggers MEDIUM sizing
  service_account_email = module.iam.service_account_emails["airflow"]
  network_id            = "default" # Replace with actual VPC network self_link in production
  subnet_id             = "default" # Replace with actual subnet self_link in production
  labels                = local.common_labels
}

# ---------------------------------------------------------------------------
# Module: Disaster Recovery
# ---------------------------------------------------------------------------
module "disaster_recovery" {
  source = "../../modules/disaster_recovery"

  project_id              = var.project_id
  region                  = var.region
  backup_region           = "us-east1"
  environment             = local.environment
  source_datasets         = module.bigquery.dataset_ids
  snapshot_retention_days = 30 # Prod: 30-day retention for compliance
  labels                  = local.common_labels
}
