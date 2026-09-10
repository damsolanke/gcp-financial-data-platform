# -----------------------------------------------------------------------------
# BigQuery Module
# -----------------------------------------------------------------------------
# This module provisions the analytical warehouse layer for the financial data
# platform. Every dataset is named fdp_<env>_<layer>; the same scheme is used
# by dbt (profiles.yml + dbt_project.yml), the Airflow DAG, the governance
# service and docker-compose. Layers:
#   raw          -> landing tables written by the Airflow DAG; rows are event
#                   payloads exactly as published (schemas/*.json)
#   staging      -> dbt views (stg_*) that parse and dedupe the raw tables
#   intermediate -> dbt ephemeral models; the dataset exists for ad-hoc use
#   marts_*      -> business-domain tables built by dbt
#   audit        -> immutable log of access, changes, anomalies, pipeline runs
#
# Only raw and audit tables are defined here. Terraform creates the staging
# and marts datasets as empty containers: their contents are dbt-managed
# relations (views/tables) and defining the same names here would collide.
#
# Separation into distinct datasets enables fine-grained IAM at the dataset
# level, which is the smallest BigQuery scope that supports access controls
# without resorting to row-level / column-level security for every table.
# -----------------------------------------------------------------------------

locals {
  # Centralise the naming convention so downstream references stay consistent
  # even if the pattern changes.
  dataset_prefix = "fdp_${var.environment}"

  # Merge module-level labels with the environment tag so every resource is
  # traceable to its environment and owning team.
  common_labels = merge(var.labels, {
    environment = var.environment
    managed_by  = "terraform"
    module      = "bigquery"
  })
}

# ---------------------------------------------------------------------------
# Datasets
# ---------------------------------------------------------------------------

# Raw: landing zone for validated events pulled from Pub/Sub by the Airflow
# DAG (load_to_staging task). This is the dbt `raw` source.
resource "google_bigquery_dataset" "raw" {
  project                     = var.project_id
  dataset_id                  = "${local.dataset_prefix}_raw"
  friendly_name               = "Raw - ${var.environment}"
  description                 = "Landing tables for validated financial events, exactly as published to Pub/Sub plus ingestion_timestamp. Read by dbt staging views; never queried by analysts."
  location                    = var.region
  default_table_expiration_ms = null # Retained indefinitely; the raw layer is the replay source for dbt
  delete_contents_on_destroy  = !var.deletion_protection
  labels                      = local.common_labels
}

# Staging: dbt-owned views (stg_*) over the raw tables. Terraform creates the
# dataset only; the views are created by `dbt run`.
resource "google_bigquery_dataset" "staging" {
  project                     = var.project_id
  dataset_id                  = "${local.dataset_prefix}_staging"
  friendly_name               = "Staging - ${var.environment}"
  description                 = "dbt staging layer: deduplicated, typed views over fdp_${var.environment}_raw. Contents are managed by dbt."
  location                    = var.region
  default_table_expiration_ms = null # Staging data is retained indefinitely; lifecycle managed by dbt snapshots
  delete_contents_on_destroy  = !var.deletion_protection
  labels                      = local.common_labels
}

# Intermediate: transformation workspace used by dbt. Not exposed to analysts.
resource "google_bigquery_dataset" "intermediate" {
  project                     = var.project_id
  dataset_id                  = "${local.dataset_prefix}_intermediate"
  friendly_name               = "Intermediate - ${var.environment}"
  description                 = "Intermediate transformation layer. Contains cleaned, joined, and deduped data. Not for direct analyst consumption."
  location                    = var.region
  default_table_expiration_ms = null
  delete_contents_on_destroy  = !var.deletion_protection
  labels                      = local.common_labels
}

# Marts - Finance: revenue, cost, and attribution facts consumed by the
# finance team and executive dashboards.
resource "google_bigquery_dataset" "marts_finance" {
  project                     = var.project_id
  dataset_id                  = "${local.dataset_prefix}_marts_finance"
  friendly_name               = "Finance Marts - ${var.environment}"
  description                 = "Business-ready finance facts: revenue summaries, cost attribution, product-region breakdowns. Consumed by Looker and finance APIs."
  location                    = var.region
  default_table_expiration_ms = null
  delete_contents_on_destroy  = !var.deletion_protection
  labels                      = local.common_labels
}

# Marts - Analytics: usage metrics and unit economics for product and growth
# teams.
resource "google_bigquery_dataset" "marts_analytics" {
  project                     = var.project_id
  dataset_id                  = "${local.dataset_prefix}_marts_analytics"
  friendly_name               = "Analytics Marts - ${var.environment}"
  description                 = "Product analytics facts: customer usage reports and unit economics. Consumed by growth and product teams."
  location                    = var.region
  default_table_expiration_ms = null
  delete_contents_on_destroy  = !var.deletion_protection
  labels                      = local.common_labels
}

# Audit: immutable record of platform operations. Kept in its own dataset so
# governance-sa can have read-only access without touching business data.
resource "google_bigquery_dataset" "audit" {
  project                     = var.project_id
  dataset_id                  = "${local.dataset_prefix}_audit"
  friendly_name               = "Audit - ${var.environment}"
  description                 = "Immutable audit trail: access logs, permission changes, anomaly alerts, and pipeline run metadata. Retention follows compliance requirements."
  location                    = var.region
  default_table_expiration_ms = null
  delete_contents_on_destroy  = !var.deletion_protection
  labels                      = local.common_labels
}

# ---------------------------------------------------------------------------
# Raw Landing Tables
# ---------------------------------------------------------------------------
# One table per event type. Columns are exactly the properties of the
# corresponding JSON Schema in schemas/ (timestamp is kept as the published
# ISO 8601 string; dbt's parse_event_timestamp macro converts it) plus
# ingestion_timestamp, the BigQuery write time used for deduplication order,
# incremental processing and the DAG's freshness check.

resource "google_bigquery_table" "raw_revenue_transactions" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "raw_revenue_transactions"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "ingestion_timestamp"
  }

  schema = jsonencode([
    { name = "transaction_id", type = "STRING", mode = "REQUIRED", description = "Unique transaction identifier (UUID); deduplication key" },
    { name = "timestamp", type = "STRING", mode = "REQUIRED", description = "ISO 8601 timestamp as published (parsed by dbt)" },
    { name = "amount_cents", type = "INT64", mode = "REQUIRED", description = "Transaction amount in cents; always positive" },
    { name = "currency", type = "STRING", mode = "REQUIRED", description = "ISO 4217 currency code" },
    { name = "customer_id", type = "STRING", mode = "REQUIRED", description = "Customer identifier" },
    { name = "product_line", type = "STRING", mode = "REQUIRED", description = "api_usage | enterprise_license | professional_services" },
    { name = "region", type = "STRING", mode = "REQUIRED", description = "us-east | us-west | eu-west | ap-southeast" },
    { name = "metadata", type = "JSON", mode = "NULLABLE", description = "Optional key-value metadata object from the event" },
    { name = "ingestion_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When this row was written to BigQuery" },
  ])
}

resource "google_bigquery_table" "raw_usage_metrics" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "raw_usage_metrics"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "ingestion_timestamp"
  }

  # quantity is FLOAT64 because compute_hours is fractional (e.g. 0.25).
  schema = jsonencode([
    { name = "metric_id", type = "STRING", mode = "REQUIRED", description = "Unique metric event identifier (UUID); deduplication key" },
    { name = "timestamp", type = "STRING", mode = "REQUIRED", description = "ISO 8601 timestamp as published (parsed by dbt)" },
    { name = "customer_id", type = "STRING", mode = "REQUIRED", description = "Customer to which this usage is attributed" },
    { name = "metric_type", type = "STRING", mode = "REQUIRED", description = "api_calls | tokens_processed | compute_hours" },
    { name = "quantity", type = "FLOAT64", mode = "REQUIRED", description = "Measured quantity; non-negative" },
    { name = "unit", type = "STRING", mode = "REQUIRED", description = "Unit of measurement (calls, tokens, hours)" },
    { name = "ingestion_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When this row was written to BigQuery" },
  ])
}

resource "google_bigquery_table" "raw_cost_records" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.raw.dataset_id
  table_id            = "raw_cost_records"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "ingestion_timestamp"
  }

  schema = jsonencode([
    { name = "record_id", type = "STRING", mode = "REQUIRED", description = "Unique cost record identifier (UUID); deduplication key" },
    { name = "timestamp", type = "STRING", mode = "REQUIRED", description = "ISO 8601 timestamp as published (parsed by dbt)" },
    { name = "cost_center", type = "STRING", mode = "REQUIRED", description = "Cost center responsible for the expenditure" },
    { name = "category", type = "STRING", mode = "REQUIRED", description = "compute | storage | network | personnel" },
    { name = "amount_cents", type = "INT64", mode = "REQUIRED", description = "Cost in cents; may be negative for credits" },
    { name = "currency", type = "STRING", mode = "REQUIRED", description = "ISO 4217 currency code" },
    { name = "vendor", type = "STRING", mode = "NULLABLE", description = "External vendor name, if applicable" },
    { name = "description", type = "STRING", mode = "NULLABLE", description = "Human-readable description of the cost" },
    { name = "ingestion_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When this row was written to BigQuery" },
  ])
}

# ---------------------------------------------------------------------------
# Marts - Finance Tables
# ---------------------------------------------------------------------------
# All finance mart tables are DAY-partitioned and clustered to optimise the
# most common query patterns: filtering by date range, then by product line
# and/or region. Partition pruning alone cuts scan costs by 10-100x for
# typical dashboard queries.

resource "google_bigquery_table" "fct_daily_revenue_summary" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.marts_finance.dataset_id
  table_id            = "fct_daily_revenue_summary"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "revenue_date"
  }

  clustering = ["product_line", "region"]

  # Schema is intentionally left to dbt to manage via on_schema_change="sync_all_columns".
  # Terraform creates the table shell; dbt owns the column definitions.
  schema = jsonencode([
    { name = "revenue_date", type = "DATE", mode = "REQUIRED", description = "The calendar date this summary covers" },
    { name = "product_line", type = "STRING", mode = "REQUIRED", description = "Product line for revenue segmentation" },
    { name = "region", type = "STRING", mode = "REQUIRED", description = "Geographic region" },
    { name = "currency", type = "STRING", mode = "REQUIRED", description = "ISO 4217 currency code" },
    { name = "total_cents", type = "INT64", mode = "REQUIRED", description = "Total revenue in smallest currency unit" },
    { name = "txn_count", type = "INT64", mode = "REQUIRED", description = "Number of transactions in this summary" },
    { name = "updated_at", type = "TIMESTAMP", mode = "REQUIRED", description = "When this summary was last computed" },
  ])
}

resource "google_bigquery_table" "fct_monthly_cost_attribution" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.marts_finance.dataset_id
  table_id            = "fct_monthly_cost_attribution"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "cost_month"
  }

  clustering = ["product_line", "region"]

  schema = jsonencode([
    { name = "cost_month", type = "DATE", mode = "REQUIRED", description = "First day of the month this attribution covers" },
    { name = "product_line", type = "STRING", mode = "REQUIRED", description = "Product line the cost is attributed to" },
    { name = "region", type = "STRING", mode = "REQUIRED", description = "Geographic region" },
    { name = "cost_center", type = "STRING", mode = "REQUIRED", description = "Organizational cost center" },
    { name = "category", type = "STRING", mode = "REQUIRED", description = "Cost category" },
    { name = "total_cents", type = "INT64", mode = "REQUIRED", description = "Total attributed cost in smallest currency unit" },
    { name = "updated_at", type = "TIMESTAMP", mode = "REQUIRED", description = "When this attribution was last computed" },
  ])
}

resource "google_bigquery_table" "fct_revenue_by_product_region" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.marts_finance.dataset_id
  table_id            = "fct_revenue_by_product_region"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "revenue_date"
  }

  clustering = ["product_line", "region"]

  schema = jsonencode([
    { name = "revenue_date", type = "DATE", mode = "REQUIRED", description = "Calendar date of the revenue" },
    { name = "product_line", type = "STRING", mode = "REQUIRED", description = "Product line" },
    { name = "region", type = "STRING", mode = "REQUIRED", description = "Geographic region" },
    { name = "currency", type = "STRING", mode = "REQUIRED", description = "ISO 4217 currency code" },
    { name = "total_cents", type = "INT64", mode = "REQUIRED", description = "Total revenue in smallest currency unit" },
    { name = "txn_count", type = "INT64", mode = "REQUIRED", description = "Number of transactions" },
    { name = "avg_cents", type = "INT64", mode = "NULLABLE", description = "Average transaction value in smallest currency unit" },
    { name = "updated_at", type = "TIMESTAMP", mode = "REQUIRED", description = "When this row was last computed" },
  ])
}

# ---------------------------------------------------------------------------
# Marts - Analytics Tables
# ---------------------------------------------------------------------------

resource "google_bigquery_table" "fct_customer_usage_report" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.marts_analytics.dataset_id
  table_id            = "fct_customer_usage_report"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  # Partitioned by report date so product teams can efficiently query recent
  # usage trends without scanning historical data.
  time_partitioning {
    type  = "DAY"
    field = "report_date"
  }

  clustering = ["customer_id", "metric_type"]

  schema = jsonencode([
    { name = "report_date", type = "DATE", mode = "REQUIRED", description = "Calendar date of the usage report" },
    { name = "customer_id", type = "STRING", mode = "REQUIRED", description = "Customer identifier" },
    { name = "metric_type", type = "STRING", mode = "REQUIRED", description = "Category of usage metric" },
    { name = "total_quantity", type = "FLOAT64", mode = "REQUIRED", description = "Aggregated usage quantity for the day" },
    { name = "unit", type = "STRING", mode = "REQUIRED", description = "Unit of measurement" },
    { name = "updated_at", type = "TIMESTAMP", mode = "REQUIRED", description = "When this report row was last computed" },
  ])
}

resource "google_bigquery_table" "fct_unit_economics" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.marts_analytics.dataset_id
  table_id            = "fct_unit_economics"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  # Unit economics (revenue per user, cost per unit) are computed monthly.
  time_partitioning {
    type  = "DAY"
    field = "period_date"
  }

  clustering = ["product_line", "region"]

  schema = jsonencode([
    { name = "period_date", type = "DATE", mode = "REQUIRED", description = "First day of the period this calculation covers" },
    { name = "product_line", type = "STRING", mode = "REQUIRED", description = "Product line" },
    { name = "region", type = "STRING", mode = "REQUIRED", description = "Geographic region" },
    { name = "revenue_per_user_cents", type = "INT64", mode = "NULLABLE", description = "Average revenue per user in smallest currency unit" },
    { name = "cost_per_unit_cents", type = "INT64", mode = "NULLABLE", description = "Cost per unit of service in smallest currency unit" },
    { name = "gross_margin_bps", type = "INT64", mode = "NULLABLE", description = "Gross margin in basis points (100 = 1%)" },
    { name = "active_users", type = "INT64", mode = "NULLABLE", description = "Number of active users in the period" },
    { name = "updated_at", type = "TIMESTAMP", mode = "REQUIRED", description = "When this row was last computed" },
  ])
}

# ---------------------------------------------------------------------------
# Audit Tables
# ---------------------------------------------------------------------------
# Audit tables are append-only by convention (enforced via IAM, not schema).
# They support compliance, incident response, and platform observability.

resource "google_bigquery_table" "access_log" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.audit.dataset_id
  table_id            = "access_log"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "event_timestamp"
  }

  schema = jsonencode([
    { name = "event_id", type = "STRING", mode = "REQUIRED", description = "Unique event identifier" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When the access event occurred" },
    { name = "principal", type = "STRING", mode = "REQUIRED", description = "Identity that performed the access (email or SA)" },
    { name = "resource", type = "STRING", mode = "REQUIRED", description = "Fully qualified resource name that was accessed" },
    { name = "action", type = "STRING", mode = "REQUIRED", description = "Action performed (read, write, delete, etc.)" },
    { name = "result", type = "STRING", mode = "REQUIRED", description = "Outcome of the action (success, denied, error)" },
    { name = "source_ip", type = "STRING", mode = "NULLABLE", description = "Source IP address of the request" },
    { name = "user_agent", type = "STRING", mode = "NULLABLE", description = "User agent string of the client" },
  ])
}

resource "google_bigquery_table" "permission_changes" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.audit.dataset_id
  table_id            = "permission_changes"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "event_timestamp"
  }

  schema = jsonencode([
    { name = "change_id", type = "STRING", mode = "REQUIRED", description = "Unique change event identifier" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When the permission change occurred" },
    { name = "changed_by", type = "STRING", mode = "REQUIRED", description = "Identity that made the change" },
    { name = "target_resource", type = "STRING", mode = "REQUIRED", description = "Resource whose permissions were modified" },
    { name = "target_principal", type = "STRING", mode = "REQUIRED", description = "Identity whose access was modified" },
    { name = "old_role", type = "STRING", mode = "NULLABLE", description = "Previous role binding, null if newly granted" },
    { name = "new_role", type = "STRING", mode = "NULLABLE", description = "New role binding, null if revoked" },
    { name = "justification", type = "STRING", mode = "NULLABLE", description = "Business justification for the change" },
  ])
}

resource "google_bigquery_table" "anomaly_alerts" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.audit.dataset_id
  table_id            = "anomaly_alerts"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "detected_at"
  }

  schema = jsonencode([
    { name = "alert_id", type = "STRING", mode = "REQUIRED", description = "Unique alert identifier" },
    { name = "detected_at", type = "TIMESTAMP", mode = "REQUIRED", description = "When the anomaly was detected" },
    { name = "alert_type", type = "STRING", mode = "REQUIRED", description = "Category of anomaly (volume_spike, schema_drift, latency, etc.)" },
    { name = "severity", type = "STRING", mode = "REQUIRED", description = "Alert severity: INFO, WARNING, CRITICAL" },
    { name = "source", type = "STRING", mode = "REQUIRED", description = "Component or pipeline that raised the alert" },
    { name = "description", type = "STRING", mode = "NULLABLE", description = "Human-readable description of the anomaly" },
    { name = "resolved_at", type = "TIMESTAMP", mode = "NULLABLE", description = "When the anomaly was resolved, null if open" },
    { name = "resolved_by", type = "STRING", mode = "NULLABLE", description = "Identity that resolved the alert" },
  ])
}

resource "google_bigquery_table" "pipeline_audit_log" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.audit.dataset_id
  table_id            = "pipeline_audit_log"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  time_partitioning {
    type  = "DAY"
    field = "started_at"
  }

  schema = jsonencode([
    { name = "run_id", type = "STRING", mode = "REQUIRED", description = "Unique pipeline run identifier (Airflow run_id or similar)" },
    { name = "dag_id", type = "STRING", mode = "REQUIRED", description = "Identifier of the DAG or pipeline definition" },
    { name = "task_id", type = "STRING", mode = "NULLABLE", description = "Identifier of the specific task within the DAG" },
    { name = "started_at", type = "TIMESTAMP", mode = "REQUIRED", description = "When the pipeline run started" },
    { name = "finished_at", type = "TIMESTAMP", mode = "NULLABLE", description = "When the pipeline run finished, null if still running" },
    { name = "status", type = "STRING", mode = "REQUIRED", description = "Run status: running, success, failed, retry" },
    { name = "rows_affected", type = "INT64", mode = "NULLABLE", description = "Number of rows processed by this run" },
    { name = "error_message", type = "STRING", mode = "NULLABLE", description = "Error details if the run failed" },
  ])
}

# ---------------------------------------------------------------------------
# Authorized View for Row-Level Security
# ---------------------------------------------------------------------------
# This authorized view restricts finance mart data by region. Analysts in a
# given region only see rows matching their assigned region. This avoids
# granting direct table access and instead channels all reads through the view.
# The view is authorized on the marts_finance dataset, meaning it can read
# the underlying tables even though the querying user cannot.

resource "google_bigquery_table" "region_scoped_revenue_view" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.marts_finance.dataset_id
  table_id            = "vw_region_scoped_daily_revenue"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  view {
    # SESSION_USER() returns the email of the querying principal. The region
    # mapping would be maintained in a separate lookup table; here we use a
    # simple CASE as a placeholder pattern. In production, replace with a join
    # to a region_access_control table.
    query = <<-SQL
      SELECT
        r.revenue_date,
        r.product_line,
        r.region,
        r.currency,
        r.total_cents,
        r.txn_count,
        r.updated_at
      FROM `${var.project_id}.${google_bigquery_dataset.marts_finance.dataset_id}.fct_daily_revenue_summary` AS r
      INNER JOIN `${var.project_id}.${google_bigquery_dataset.audit.dataset_id}.access_log` AS acl
        ON acl.principal = SESSION_USER()
        AND acl.resource = r.region
      WHERE r.region IS NOT NULL
    SQL

    use_legacy_sql = false
  }
}

# Grant the view authorization to read from marts_finance tables.
# Without this, the view would fail with permission errors when a user
# who only has view-level access tries to query it.
resource "google_bigquery_dataset_access" "authorized_view" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.marts_finance.dataset_id

  view {
    project_id = var.project_id
    dataset_id = google_bigquery_dataset.marts_finance.dataset_id
    table_id   = google_bigquery_table.region_scoped_revenue_view.table_id
  }
}
