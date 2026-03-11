variable "project_id" {
  description = "The GCP project ID where Bigtable resources will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "zone" {
  description = "The GCP zone for the Bigtable cluster. Bigtable clusters are zonal, so this must be a specific zone within the target region."
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]-[a-z]$", var.zone))
    error_message = "Zone must be a valid GCP zone identifier (e.g., us-central1-a)."
  }
}

variable "instance_name" {
  description = "Name for the Bigtable instance. Kept short because it appears in monitoring and billing dashboards."
  type        = string
  default     = "financial-events"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,32}$", var.instance_name))
    error_message = "Instance name must start with a letter, contain only lowercase letters, numbers, and hyphens, and be at most 33 characters."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Affects instance display name and labels."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "num_nodes" {
  description = "Number of nodes in the Bigtable cluster. Minimum 1 for dev, recommend 3+ for prod to handle failover and throughput requirements."
  type        = number
  default     = 1

  validation {
    condition     = var.num_nodes >= 1 && var.num_nodes <= 30
    error_message = "Number of nodes must be between 1 and 30."
  }
}

variable "storage_type" {
  description = "Storage type for the Bigtable cluster. SSD for low-latency financial event lookups; HDD only suitable for archival workloads."
  type        = string
  default     = "SSD"

  validation {
    condition     = contains(["SSD", "HDD"], var.storage_type)
    error_message = "Storage type must be either SSD or HDD."
  }
}

variable "labels" {
  description = "Labels to apply to all Bigtable resources for cost tracking and organizational grouping"
  type        = map(string)
  default     = {}
}
