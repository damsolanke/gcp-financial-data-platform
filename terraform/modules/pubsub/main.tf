# -----------------------------------------------------------------------------
# Pub/Sub Module
# -----------------------------------------------------------------------------
# Pub/Sub is the backbone of the event-driven ingestion pipeline. Financial
# events flow through two topics:
#
#   1. financial-events-validated: receives events that have passed schema
#      validation in the ingestion service. The subscription delivers these
#      to the processing pipeline (Dataflow or direct BigQuery/Bigtable writes).
#
#   2. financial-events-dead-letter: captures messages that failed processing
#      after max_delivery_attempts retries. These are retained for 30 days
#      to allow investigation and manual replay.
#
# Exactly-once delivery is enabled because financial transactions must not be
# duplicated — a duplicate write to the revenue table directly impacts
# financial reporting accuracy.
# -----------------------------------------------------------------------------

locals {
  common_labels = merge(var.labels, {
    environment = var.environment
    managed_by  = "terraform"
    module      = "pubsub"
  })
}

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------
# Schema enforcement at the Pub/Sub level provides a first line of defense
# against malformed messages before they reach the processing pipeline.
# This catches issues at publish time rather than at processing time,
# reducing DLQ volume and alerting lag.

resource "google_pubsub_schema" "revenue_transaction_schema" {
  project = var.project_id
  name    = "revenue-transaction-schema-${var.environment}"
  type    = "AVRO"
  definition = jsonencode({
    type = "record"
    name = "RevenueTransaction"
    fields = [
      { name = "transaction_id", type = "string" },
      { name = "event_timestamp", type = "string" },
      { name = "amount_cents", type = "long" },
      { name = "currency", type = "string" },
      { name = "customer_id", type = "string" },
      { name = "product_line", type = ["null", "string"], default = null },
      { name = "region", type = ["null", "string"], default = null },
      { name = "source_system", type = "string" },
    ]
  })
}

# ---------------------------------------------------------------------------
# Topics
# ---------------------------------------------------------------------------

# Primary topic for validated financial events. Message retention is set to
# 7 days so messages survive subscriber outages without data loss.
resource "google_pubsub_topic" "validated" {
  project                    = var.project_id
  name                       = "financial-events-validated-${var.environment}"
  message_retention_duration = var.message_retention_duration
  labels                     = local.common_labels

  # Bind the schema to enforce message structure at publish time.
  # JSON encoding is used because it's human-readable in logs and debugging.
  schema_settings {
    schema   = google_pubsub_schema.revenue_transaction_schema.id
    encoding = "JSON"
  }

  depends_on = [google_pubsub_schema.revenue_transaction_schema]
}

# Dead-letter topic. No schema enforcement here because DLQ messages may
# be malformed (that's why they're in the DLQ).
resource "google_pubsub_topic" "dead_letter" {
  project                    = var.project_id
  name                       = "financial-events-dead-letter-${var.environment}"
  message_retention_duration = var.dlq_retention
  labels                     = local.common_labels
}

# ---------------------------------------------------------------------------
# Subscriptions
# ---------------------------------------------------------------------------

# Primary subscription on the validated topic. Configuration choices:
# - ack_deadline=600s: processing a batch of financial events (validation,
#   enrichment, BigQuery write) can take several minutes under load.
# - exactly_once_delivery: critical for financial data — duplicate messages
#   would cause incorrect revenue/cost figures.
# - retry_policy: exponential backoff from 10s to 600s gives transient
#   failures (e.g., BigQuery quota exhaustion) time to recover.
# - dead_letter_policy: after 5 failed attempts, messages move to DLQ
#   for manual investigation rather than blocking the subscription.
resource "google_pubsub_subscription" "validated" {
  project = var.project_id
  name    = "financial-events-validated-sub-${var.environment}"
  topic   = google_pubsub_topic.validated.id
  labels  = local.common_labels

  ack_deadline_seconds         = 600
  enable_exactly_once_delivery = true
  message_retention_duration   = var.message_retention_duration

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  # Enable message ordering within a partition key (customer_id).
  # This ensures events for the same customer are processed in order,
  # which matters for stateful processing like running balances.
  enable_message_ordering = true
}

# DLQ subscription: allows operators to pull and inspect failed messages.
# Longer retention (30 days) because DLQ investigation may take time.
# No dead-letter policy on the DLQ subscription itself to avoid infinite loops.
resource "google_pubsub_subscription" "dead_letter" {
  project = var.project_id
  name    = "financial-events-dlq-sub-${var.environment}"
  topic   = google_pubsub_topic.dead_letter.id
  labels  = local.common_labels

  ack_deadline_seconds       = 600
  message_retention_duration = var.dlq_retention

  # No retry or dead-letter policy on the DLQ subscription.
  # Failed DLQ messages should be investigated manually, not retried automatically.
}
