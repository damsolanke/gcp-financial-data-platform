variable "project_id" {
  description = "The GCP project ID where IAM resources (service accounts, roles, bindings) will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Used in service account naming and to scope custom roles."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "bigquery_datasets" {
  description = "Map of logical dataset names to their BigQuery dataset IDs. Used to create dataset-level IAM bindings. Expected keys: staging, intermediate, marts_finance, marts_analytics, audit."
  type        = map(string)

  validation {
    condition     = contains(keys(var.bigquery_datasets), "audit")
    error_message = "bigquery_datasets must include at least the 'audit' key."
  }
}

variable "labels" {
  description = "Labels for organizational grouping. Not directly applied to IAM resources (which don't support labels) but used in descriptions."
  type        = map(string)
  default     = {}
}
