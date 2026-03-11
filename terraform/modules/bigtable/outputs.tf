output "instance_id" {
  description = "The full resource ID of the Bigtable instance, used for IAM bindings and monitoring configuration."
  value       = google_bigtable_instance.financial_events.id
}

output "instance_name" {
  description = "The short name of the Bigtable instance, used by application code to establish connections."
  value       = google_bigtable_instance.financial_events.name
}

output "table_name" {
  description = "The name of the financial_events table within the instance, used by the ingestion and query services."
  value       = google_bigtable_table.financial_events.name
}
