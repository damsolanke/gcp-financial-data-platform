variable "project_id" {
  description = "The GCP project ID where BigQuery resources will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "region" {
  description = "The default region for BigQuery dataset location. Also used for processing location."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "Region must be a valid GCP region identifier (e.g., us-central1)."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Controls naming and protection settings."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "deletion_protection" {
  description = "Prevents accidental deletion of datasets. Should be true in prod, can be false in dev for iteration speed."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels to apply to all BigQuery resources for cost tracking and organizational grouping"
  type        = map(string)
  default     = {}
}
