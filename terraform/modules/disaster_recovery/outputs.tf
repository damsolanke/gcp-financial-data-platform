output "transfer_config_ids" {
  description = "Map of dataset names to their BigQuery Data Transfer Config IDs, used for monitoring transfer run status and alerting on failures."
  value = {
    for key, config in google_bigquery_data_transfer_config.dataset_snapshots :
    key => config.id
  }
}

output "recovery_rto_target" {
  description = "Recovery Time Objective: maximum acceptable time from incident detection to full service restoration."
  value       = "45 minutes"
}

output "recovery_rpo_target" {
  description = "Recovery Point Objective: maximum acceptable data loss measured in time. Snapshots run daily; Pub/Sub retention covers the gap."
  value       = "1 hour"
}

output "recovery_procedure" {
  description = "Step-by-step recovery procedure document for inclusion in runbooks and incident response playbooks."
  value       = local.recovery_procedure
}

output "snapshot_dataset_id" {
  description = "The BigQuery dataset ID where DR snapshots are stored, used for monitoring and validation queries."
  value       = google_bigquery_dataset.snapshots.dataset_id
}
