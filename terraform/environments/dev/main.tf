# -----------------------------------------------------------------------------
# Development Environment
# -----------------------------------------------------------------------------
# This is the dev environment root module. It wires together all platform
# modules with development-appropriate settings:
#   - Deletion protection disabled for fast iteration
#   - Minimum node/replica counts to reduce costs
#   - Small Composer environment
#   - Local backend (no shared state locking needed for individual dev work)
#
# To apply: cd terraform/environments/dev && terraform init && terraform apply
# -----------------------------------------------------------------------------

terraform {
  # Local backend is sufficient for dev because each developer typically has
  # their own GCP project and doesn't need shared state locking.
  backend "local" {
    path = "terraform.tfstate"
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

# The Kubernetes provider is configured after the GKE cluster is created.
# For dev, this may not be needed if Kubernetes is disabled.
provider "kubernetes" {
  host                   = try(module.kubernetes.cluster_endpoint, "")
  cluster_ca_certificate = try(base64decode(module.kubernetes.cluster_ca_certificate), "")
  token                  = try(data.google_client_config.default.access_token, "")
}

data "google_client_config" "default" {}

locals {
  environment = "dev"

  # Standard labels applied to all resources for cost tracking and ownership.
  common_labels = {
    environment = "dev"
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
  deletion_protection = false # Dev: allow fast iteration without manual cleanup
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
  num_nodes     = 1 # Dev: single node to minimize cost
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
  message_retention_duration = "604800s"  # 7 days
  dlq_retention              = "2592000s" # 30 days
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
# In dev, the GKE cluster can be conditionally created. Set enable_kubernetes
# to false in tfvars to skip cluster creation and reduce costs for local
# development that only needs BigQuery/Pub/Sub.
module "kubernetes" {
  source = "../../modules/kubernetes"

  project_id          = var.project_id
  region              = var.region
  environment         = local.environment
  network_id          = "default"
  subnet_id           = "default"
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
  environment           = local.environment
  service_account_email = module.iam.service_account_emails["airflow"]
  network_id            = "default"
  subnet_id             = "default"
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
  snapshot_retention_days = 7 # Dev: shorter retention to reduce storage costs
  labels                  = local.common_labels
}
