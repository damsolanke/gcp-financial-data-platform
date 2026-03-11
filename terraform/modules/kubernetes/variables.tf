variable "project_id" {
  description = "The GCP project ID where the GKE cluster and workloads will be created"
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "Project ID must not be empty."
  }
}

variable "region" {
  description = "The GCP region for the GKE cluster. Regional clusters provide higher availability than zonal."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "Region must be a valid GCP region identifier (e.g., us-central1)."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod). Controls cluster sizing, replica counts, and network policy strictness."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "network_id" {
  description = "The self_link or ID of the VPC network for the GKE cluster. Must have appropriate firewall rules and secondary ranges configured."
  type        = string
}

variable "subnet_id" {
  description = "The self_link or ID of the subnet for the GKE cluster. Must have secondary IP ranges for pods and services."
  type        = string
}

variable "ingestion_sa_email" {
  description = "Email of the ingestion service account for Workload Identity annotation on the ingestion deployment."
  type        = string
}

variable "governance_sa_email" {
  description = "Email of the governance service account for Workload Identity annotation on the governance deployment."
  type        = string
}

variable "labels" {
  description = "Labels to apply to all Kubernetes resources for cost tracking and organizational grouping"
  type        = map(string)
  default     = {}
}
