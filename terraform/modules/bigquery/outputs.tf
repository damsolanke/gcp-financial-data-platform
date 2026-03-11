output "dataset_ids" {
  description = "Map of logical dataset names to their BigQuery dataset IDs, used by downstream modules (IAM, dbt, Composer) to reference datasets."
  value = {
    staging         = google_bigquery_dataset.staging.dataset_id
    intermediate    = google_bigquery_dataset.intermediate.dataset_id
    marts_finance   = google_bigquery_dataset.marts_finance.dataset_id
    marts_analytics = google_bigquery_dataset.marts_analytics.dataset_id
    audit           = google_bigquery_dataset.audit.dataset_id
  }
}

output "staging_table_ids" {
  description = "Map of staging table names to their fully qualified table IDs, used by ingestion services to target writes."
  value = {
    stg_revenue_transactions = google_bigquery_table.stg_revenue_transactions.table_id
    stg_usage_metrics        = google_bigquery_table.stg_usage_metrics.table_id
    stg_cost_records         = google_bigquery_table.stg_cost_records.table_id
  }
}

output "mart_table_ids" {
  description = "Map of all mart table names to their table IDs, consumed by BI tools and downstream APIs."
  value = {
    fct_daily_revenue_summary     = google_bigquery_table.fct_daily_revenue_summary.table_id
    fct_monthly_cost_attribution  = google_bigquery_table.fct_monthly_cost_attribution.table_id
    fct_revenue_by_product_region = google_bigquery_table.fct_revenue_by_product_region.table_id
    fct_customer_usage_report     = google_bigquery_table.fct_customer_usage_report.table_id
    fct_unit_economics            = google_bigquery_table.fct_unit_economics.table_id
  }
}

output "audit_table_ids" {
  description = "Map of audit table names to their table IDs, used by the governance service and compliance dashboards."
  value = {
    access_log         = google_bigquery_table.access_log.table_id
    permission_changes = google_bigquery_table.permission_changes.table_id
    anomaly_alerts     = google_bigquery_table.anomaly_alerts.table_id
    pipeline_audit_log = google_bigquery_table.pipeline_audit_log.table_id
  }
}
