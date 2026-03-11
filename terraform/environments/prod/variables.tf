variable "project_id" {
  description = "The GCP project ID for the production environment"
  type        = string
}

variable "region" {
  description = "The primary GCP region for all resources. Default region balances cost, latency, and service availability."
  type        = string
  default     = "us-central1"
}
