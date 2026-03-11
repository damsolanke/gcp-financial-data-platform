variable "project_id" {
  description = "The GCP project ID for the development environment"
  type        = string
}

variable "region" {
  description = "The primary GCP region for all resources. Default region balances cost and latency for US-based development."
  type        = string
  default     = "us-central1"
}
