output "composer_environment_id" {
  description = "The full resource ID of the Composer environment, used for monitoring and management API calls."
  value       = google_composer_environment.main.id
}

output "airflow_uri" {
  description = "The URI of the Airflow web interface, used by operators and CI/CD to access the Airflow UI and REST API."
  value       = google_composer_environment.main.config[0].airflow_uri
}

output "dag_gcs_prefix" {
  description = "The GCS path prefix where DAG files should be uploaded. CI/CD pipelines sync DAG code to this location."
  value       = google_composer_environment.main.config[0].dag_gcs_prefix
}
