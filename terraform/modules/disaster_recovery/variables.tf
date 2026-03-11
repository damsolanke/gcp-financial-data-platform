variable "project_id" {
  description = "The GCP project ID where disaster recovery resources will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "region" {
  description = "The primary GCP region where source datasets and resources reside"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "Region must be a valid GCP region identifier (e.g., us-central1)."
  }
}

variable "backup_region" {
  description = "The DR region for failover. Should be geographically distant from the primary region to survive regional outages."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.backup_region))
    error_message = "Backup region must be a valid GCP region identifier (e.g., us-east1)."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). DR resources are most critical in prod but should be tested in staging."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "source_datasets" {
  description = "Map of logical dataset names to their BigQuery dataset IDs. A snapshot transfer config will be created for each dataset."
  type        = map(string)

  validation {
    condition     = length(var.source_datasets) > 0
    error_message = "At least one source dataset must be provided for DR snapshots."
  }
}

variable "snapshot_retention_days" {
  description = "Number of days to retain dataset snapshots. 30 days provides enough history to recover from delayed detection of data corruption."
  type        = number
  default     = 30

  validation {
    condition     = var.snapshot_retention_days >= 1 && var.snapshot_retention_days <= 365
    error_message = "Snapshot retention must be between 1 and 365 days."
  }
}

variable "labels" {
  description = "Labels to apply to DR resources for cost tracking and organizational grouping"
  type        = map(string)
  default     = {}
}
