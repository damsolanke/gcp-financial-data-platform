variable "project_id" {
  description = "The GCP project ID where Pub/Sub resources will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Used in resource naming and labels."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "message_retention_duration" {
  description = "How long unacknowledged messages are retained on the validated topic. 7 days (604800s) provides a buffer for extended outages without data loss."
  type        = string
  default     = "604800s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.message_retention_duration))
    error_message = "Message retention duration must be specified in seconds (e.g., '604800s')."
  }
}

variable "dlq_retention" {
  description = "How long messages are retained on the dead-letter topic. 30 days (2592000s) allows time for investigation and manual replay of failed messages."
  type        = string
  default     = "2592000s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.dlq_retention))
    error_message = "DLQ retention must be specified in seconds (e.g., '2592000s')."
  }
}

variable "labels" {
  description = "Labels to apply to all Pub/Sub resources for cost tracking and organizational grouping"
  type        = map(string)
  default     = {}
}
