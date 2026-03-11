variable "project_id" {
  description = "The GCP project ID where GCS buckets and transfer jobs will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "region" {
  description = "Primary region for regional resources. The raw bucket uses multi-region 'US' for availability, but this variable is used for labels and related config."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "Region must be a valid GCP region identifier (e.g., us-central1)."
  }
}

variable "backup_region" {
  description = "Region for the backup bucket. Should be geographically separate from the primary region for disaster recovery."
  type        = string
  default     = "us-east1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.backup_region))
    error_message = "Backup region must be a valid GCP region identifier (e.g., us-east1)."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Controls naming and lifecycle aggressiveness."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "labels" {
  description = "Labels to apply to all GCS resources for cost tracking and organizational grouping"
  type        = map(string)
  default     = {}
}
