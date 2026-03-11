output "service_account_emails" {
  description = "Map of service account function names to their email addresses, used by other modules (Kubernetes, Composer) to configure workload identity."
  value = {
    ingestion  = google_service_account.ingestion.email
    governance = google_service_account.governance.email
    airflow    = google_service_account.airflow.email
    dbt        = google_service_account.dbt.email
  }
}

output "custom_role_id" {
  description = "The fully qualified ID of the financial_auditor custom role, used for binding to auditor user accounts or groups."
  value       = google_project_iam_custom_role.financial_auditor.id
}
