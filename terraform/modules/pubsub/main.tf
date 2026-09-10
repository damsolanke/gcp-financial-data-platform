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
# Topic schema
# ---------------------------------------------------------------------------
# The validated topic deliberately has NO Pub/Sub schema attached. The
# ingestion service is the single publisher and validates every payload
# against schemas/*.json (Draft-07) before publishing; a Pub/Sub schema would
# be a second, weaker copy of that contract that could only describe one of
# the three event types the topic carries. See README.md in this module.

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
