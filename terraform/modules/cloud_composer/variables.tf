variable "project_id" {
  description = "The GCP project ID where Cloud Composer will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "region" {
  description = "The GCP region for the Composer environment. Should be the same region as BigQuery datasets and GCS buckets for data locality."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "Region must be a valid GCP region identifier (e.g., us-central1)."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Controls environment sizing, worker resources, and PyPI package versions."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "service_account_email" {
  description = "Email of the service account for the Composer environment. Must have Composer worker and necessary data access permissions."
  type        = string
}

variable "network_id" {
  description = "The self_link or ID of the VPC network for the Composer environment's GKE cluster."
  type        = string
}

variable "subnet_id" {
  description = "The self_link or ID of the subnet for the Composer environment's GKE cluster."
  type        = string
}

variable "labels" {
  description = "Labels to apply to the Composer environment for cost tracking and organizational grouping"
  type        = map(string)
  default     = {}
}
