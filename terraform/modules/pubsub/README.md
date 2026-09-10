# pubsub module

Provisions the event backbone for the platform:

| Resource | Name | Purpose |
|----------|------|---------|
| `google_pubsub_topic.validated` | `financial-events-validated-<env>` | Events that passed JSON Schema validation in the ingestion service |
| `google_pubsub_subscription.validated` | `financial-events-validated-sub-<env>` | Exactly-once, ordered pull subscription consumed by the batch pipeline; dead-letters after 5 attempts |
| `google_pubsub_topic.dead_letter` | `financial-events-dead-letter-<env>` | Events that failed validation (published directly by the ingestion service) or exhausted delivery attempts |
| `google_pubsub_subscription.dead_letter` | `financial-events-dlq-sub-<env>` | Operator subscription for inspecting and replaying failed messages |

## Why the validated topic has no Pub/Sub schema

An earlier version of this module attached an Avro schema (`RevenueTransaction`)
to the validated topic. It was removed because it could never match what is
actually published:

- The Go publisher (`ingestion-service/internal/handler/events.go`) forwards the
  event payload exactly as validated against `schemas/*.json`. Those payloads
  carry `timestamp`; the Avro schema required `event_timestamp` and
  `source_system`, which the service never sends, so every publish would have
  been rejected by Pub/Sub.
- One topic carries three event types (`revenue_transaction`, `usage_metric`,
  `cost_record`, distinguished by the `event_type` message attribute). Pub/Sub
  allows a single schema per topic, so enforcing structure at the topic level
  would require either three topics or an Avro union that duplicates the JSON
  Schemas.

The contract is therefore enforced once, at the ingestion service, and guarded
by `ingestion-service/internal/handler/contract_test.go`, which validates every
published sample payload against the canonical `schemas/*.json` with an
independent JSON Schema implementation. If topic-level enforcement is wanted
later, the right shape is one topic per event type, each with a schema
generated from the corresponding JSON Schema file.

## Inputs

| Variable | Default | Description |
|----------|---------|-------------|
| `project_id` | - | GCP project |
| `environment` | - | `dev`, `staging` or `prod`; suffixes every resource name |
| `message_retention_duration` | `604800s` (7 days) | Retention on the validated topic and subscription |
| `dlq_retention` | `2592000s` (30 days) | Retention on the dead-letter topic and subscription |
| `labels` | `{}` | Labels merged onto every resource |

## Outputs

`validated_topic_id`, `validated_topic_name`, `dlq_topic_id`, `dlq_topic_name`,
`validated_subscription_id`, `dlq_subscription_id`. The Kubernetes module wires
`validated_topic_name` and `dlq_topic_name` into the ingestion service as
`PUBSUB_TOPIC_VALIDATED` and `PUBSUB_TOPIC_DLQ`.
