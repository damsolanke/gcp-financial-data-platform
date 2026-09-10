variable "project_id" {
  description = "The GCP project ID for the development environment"
  type        = string
}

variable "region" {
  description = "The primary GCP region for all resources. Default region balances cost and latency for US-based development."
  type        = string
  default     = "us-central1"
}

variable "artifact_registry_repo" {
  description = "Artifact Registry repository holding the service images (<region>-docker.pkg.dev/<project>/<repo>). Leave null to derive <region>-docker.pkg.dev/<project_id>/financial-data-platform."
  type        = string
  default     = null
}

variable "image_tag" {
  description = "Image tag to deploy for ingestion-service and governance-service. CD passes the short commit SHA; defaults to latest."
  type        = string
  default     = "latest"
}
