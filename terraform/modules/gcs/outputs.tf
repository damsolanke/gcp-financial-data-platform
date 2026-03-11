output "raw_bucket_name" {
  description = "Name of the raw data bucket, used by ingestion services and file upload configurations."
  value       = google_storage_bucket.raw.name
}

output "raw_bucket_url" {
  description = "GCS URL of the raw data bucket (gs://...), used in Airflow DAGs and data pipeline configurations."
  value       = google_storage_bucket.raw.url
}

output "backup_bucket_name" {
  description = "Name of the backup bucket, used by disaster recovery procedures and compliance reporting."
  value       = google_storage_bucket.backup.name
}

output "backup_bucket_url" {
  description = "GCS URL of the backup bucket (gs://...), used in DR documentation and restore scripts."
  value       = google_storage_bucket.backup.url
}
