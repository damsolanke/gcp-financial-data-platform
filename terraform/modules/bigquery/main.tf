# -----------------------------------------------------------------------------
# BigQuery Module
# -----------------------------------------------------------------------------
# This module provisions the analytical warehouse layer for the financial data
# platform. The dataset topology follows the dbt-style medallion architecture:
#   staging     -> raw ingested data, schema-enforced
#   intermediate -> cleaned / joined data (not exposed to analysts)
#   marts_*     -> business-domain datasets consumed by BI tools & APIs
#   audit       -> immutable log of access, changes, and anomalies
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

# Staging: landing zone for validated events arriving from Pub/Sub and GCS.
# Tables here mirror source schemas with added lineage columns.
resource "google_bigquery_dataset" "staging" {
  project                     = var.project_id
  dataset_id                  = "${local.dataset_prefix}_staging"
  friendly_name               = "Staging - ${var.environment}"
  description                 = "Landing zone for validated financial events. Data here is append-only and schema-enforced before promotion to intermediate."
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
# Staging Tables
# ---------------------------------------------------------------------------
# Each staging table mirrors the upstream source schema with added lineage
# columns (surrogate_key, ingestion_timestamp, source_system) to enable
# deduplication and auditing in the intermediate layer.

resource "google_bigquery_table" "stg_revenue_transactions" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.staging.dataset_id
  table_id            = "stg_revenue_transactions"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  # Revenue transactions are the highest-volume staging table.
  # Schema is deliberately flat (no nested structs) to simplify dbt
  # transformations and allow streaming inserts from the ingestion service.
  schema = jsonencode([
    { name = "transaction_id", type = "STRING", mode = "REQUIRED", description = "Unique transaction identifier from the source system" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When the transaction occurred in the source system" },
    { name = "amount_cents", type = "INT64", mode = "REQUIRED", description = "Transaction amount in the smallest currency unit to avoid floating-point rounding" },
    { name = "currency", type = "STRING", mode = "REQUIRED", description = "ISO 4217 currency code (e.g., USD, EUR)" },
    { name = "customer_id", type = "STRING", mode = "REQUIRED", description = "Opaque customer identifier for join to customer dimension" },
    { name = "product_line", type = "STRING", mode = "NULLABLE", description = "Product line classification for revenue segmentation" },
    { name = "region", type = "STRING", mode = "NULLABLE", description = "Geographic region of the transaction for regulatory and reporting splits" },
    { name = "metadata", type = "JSON", mode = "NULLABLE", description = "Schemaless metadata bag for source-specific fields not yet promoted to columns" },
    { name = "surrogate_key", type = "STRING", mode = "REQUIRED", description = "SHA-256 hash of business key columns for deduplication in intermediate layer" },
    { name = "ingestion_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When this row was written to BigQuery, used for incremental processing" },
    { name = "source_system", type = "STRING", mode = "REQUIRED", description = "Identifier of the upstream system that produced this record" },
  ])
}

resource "google_bigquery_table" "stg_usage_metrics" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.staging.dataset_id
  table_id            = "stg_usage_metrics"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  # Usage metrics track per-customer consumption events (API calls, storage,
  # compute minutes). Quantity is FLOAT64 because some metrics are fractional
  # (e.g., 0.25 vCPU-hours).
  schema = jsonencode([
    { name = "metric_id", type = "STRING", mode = "REQUIRED", description = "Unique metric event identifier" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When the usage event occurred" },
    { name = "customer_id", type = "STRING", mode = "REQUIRED", description = "Customer to which this usage is attributed" },
    { name = "metric_type", type = "STRING", mode = "REQUIRED", description = "Category of usage metric (e.g., api_calls, storage_gb, compute_minutes)" },
    { name = "quantity", type = "FLOAT64", mode = "REQUIRED", description = "Measured quantity of the usage event" },
    { name = "unit", type = "STRING", mode = "REQUIRED", description = "Unit of measurement for the quantity field" },
    { name = "surrogate_key", type = "STRING", mode = "REQUIRED", description = "SHA-256 hash of business key columns for deduplication" },
    { name = "ingestion_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "BigQuery write timestamp for incremental processing" },
    { name = "source_system", type = "STRING", mode = "REQUIRED", description = "Upstream system identifier" },
  ])
}

resource "google_bigquery_table" "stg_cost_records" {
  project             = var.project_id
  dataset_id          = google_bigquery_dataset.staging.dataset_id
  table_id            = "stg_cost_records"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  # Cost records capture internal and vendor spend. Kept separate from revenue
  # because cost data typically arrives on a different cadence (daily batch vs.
  # real-time streaming) and has its own set of dimensions.
  schema = jsonencode([
    { name = "record_id", type = "STRING", mode = "REQUIRED", description = "Unique cost record identifier" },
    { name = "event_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "When the cost was incurred" },
    { name = "cost_center", type = "STRING", mode = "REQUIRED", description = "Organizational cost center for internal allocation" },
    { name = "category", type = "STRING", mode = "REQUIRED", description = "Cost category (e.g., infrastructure, personnel, licensing)" },
    { name = "amount_cents", type = "INT64", mode = "REQUIRED", description = "Cost amount in smallest currency unit" },
    { name = "currency", type = "STRING", mode = "REQUIRED", description = "ISO 4217 currency code" },
    { name = "vendor", type = "STRING", mode = "NULLABLE", description = "External vendor name, null for internal costs" },
    { name = "description", type = "STRING", mode = "NULLABLE", description = "Human-readable description of the cost line item" },
    { name = "surrogate_key", type = "STRING", mode = "REQUIRED", description = "SHA-256 hash of business key columns for deduplication" },
    { name = "ingestion_timestamp", type = "TIMESTAMP", mode = "REQUIRED", description = "BigQuery write timestamp for incremental processing" },
    { name = "source_system", type = "STRING", mode = "REQUIRED", description = "Upstream system identifier" },
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
