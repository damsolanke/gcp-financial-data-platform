variable "project_id" {
  description = "The GCP project ID where the GKE cluster and workloads will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "region" {
  description = "The GCP region for the GKE cluster. Regional clusters provide higher availability than zonal."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "Region must be a valid GCP region identifier (e.g., us-central1)."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Controls cluster sizing, replica counts, and network policy strictness."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "network_id" {
  description = "The self_link or ID of the VPC network for the GKE cluster. Must have appropriate firewall rules and secondary ranges configured."
  type        = string
}

variable "subnet_id" {
  description = "The self_link or ID of the subnet for the GKE cluster. Must have secondary IP ranges for pods and services."
  type        = string
}

variable "ingestion_sa_email" {
  description = "Email of the ingestion service account for Workload Identity annotation on the ingestion deployment."
  type        = string
}

variable "governance_sa_email" {
  description = "Email of the governance service account for Workload Identity annotation on the governance deployment."
  type        = string
}

variable "labels" {
  description = "Labels to apply to all Kubernetes resources for cost tracking and organizational grouping"
  type        = map(string)
  default     = {}
}

variable "artifact_registry_repo" {
  description = "Artifact Registry repository the CD workflow pushes images to, e.g. us-central1-docker.pkg.dev/<project>/<repo> (the ARTIFACT_REGISTRY_REPO secret in .github/workflows/cd.yml). Images are <repo>/ingestion-service:<tag> and <repo>/governance-service:<tag>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+-docker\\.pkg\\.dev/[^/]+/[^/]+$", var.artifact_registry_repo))
    error_message = "artifact_registry_repo must look like <region>-docker.pkg.dev/<project>/<repository>."
  }
}

variable "image_tag" {
  description = "Image tag to deploy for both services. CD tags images with the 7-character commit SHA and also pushes :latest."
  type        = string
  default     = "latest"
}

variable "pubsub_validated_topic" {
  description = "Short name of the validated-events topic (module.pubsub.validated_topic_name); exported to the ingestion service as PUBSUB_TOPIC_VALIDATED."
  type        = string
}

variable "pubsub_dlq_topic" {
  description = "Short name of the dead-letter topic (module.pubsub.dlq_topic_name); exported to the ingestion service as PUBSUB_TOPIC_DLQ."
  type        = string
}

variable "bigtable_instance_name" {
  description = "Bigtable instance name (module.bigtable.instance_name); exported to the ingestion service as BIGTABLE_INSTANCE_ID."
  type        = string
}

variable "bigtable_table_name" {
  description = "Bigtable table name (module.bigtable.table_name); exported to the ingestion service as BIGTABLE_TABLE_ID."
  type        = string
}

variable "audit_dataset_id" {
  description = "BigQuery audit dataset ID (module.bigquery.dataset_ids[\"audit\"], i.e. fdp_<env>_audit); exported to the governance service as BIGQUERY_DATASET_AUDIT."
  type        = string
}

variable "log_level" {
  description = "Log level exported to both services as LOG_LEVEL."
  type        = string
  default     = "info"
}
