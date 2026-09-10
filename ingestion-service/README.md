# Ingestion Service

HTTP ingestion service for the GCP Financial Data Platform. Receives financial events (revenue transactions, usage metrics, cost records), validates them against JSON schemas, publishes to Pub/Sub, and writes to Bigtable for hot-path queries.

## Architecture

```
HTTP POST /api/v1/events
        |
        v
  JSON Schema Validation
        |
   +----+----+
   |         |
   v         v
 Pub/Sub   Pub/Sub DLQ
(valid)    (invalid)
   |
   v
 Bigtable
(best-effort)
```

## API Endpoints

| Method | Path              | Description                          |
|--------|-------------------|--------------------------------------|
| POST   | /api/v1/events    | Ingest a financial event             |
| GET    | /healthz          | Static health check (always `ok`; does not probe Pub/Sub or Bigtable) |
| GET    | /metrics          | Prometheus metrics                   |

### POST /api/v1/events

Accepts event type via query parameter `?type=revenue_transaction` or as a JSON field `event_type`. An embedded `event_type` is stripped before validation and is not published: every message on the validated topic is exactly the payload that passed the schema in `schemas/` (guarded by `internal/handler/contract_test.go`).

**Supported event types:** `revenue_transaction`, `usage_metric`, `cost_record`

**Timestamps:** `timestamp` is RFC 3339; both `2025-01-15T10:30:00Z` and the generator's `2025-01-15T10:30:00.123456+00:00` are accepted and drive the Bigtable row key.

**Responses:**
- `201` - Event accepted and published
- `400` - Validation failure (with field-level errors)
- `413` - Request body exceeds 1MB
- `502` - Pub/Sub publish failure

## Configuration

| Variable                 | Default            | Description                       |
|--------------------------|--------------------|-----------------------------------|
| `PORT`                   | `8080`             | HTTP listen port                  |
| `LOG_LEVEL`              | `info`             | Zerolog level (debug, info, etc.) |
| `PUBSUB_PROJECT_ID`     | -                  | GCP project for Pub/Sub           |
| `PUBSUB_TOPIC_VALIDATED`| `validated-events` | Topic for validated events (Terraform: `financial-events-validated-<env>`) |
| `PUBSUB_TOPIC_DLQ`      | `dlq-events`       | Topic for failed events (Terraform: `financial-events-dead-letter-<env>`) |
| `BIGTABLE_PROJECT_ID`   | -                  | GCP project for Bigtable          |
| `BIGTABLE_INSTANCE_ID`  | -                  | Bigtable instance ID (Terraform: `financial-events-<env>`) |
| `BIGTABLE_TABLE_ID`     | `events`           | Bigtable table name (Terraform: `financial_events`) |

The Kubernetes module (`terraform/modules/kubernetes`) sets every variable above from the pubsub and bigtable module outputs; docker-compose uses the local emulator names.

Emulator auto-detection: set `PUBSUB_EMULATOR_HOST` and/or `BIGTABLE_EMULATOR_HOST` for local development (the Google client libraries pick these up).

## Bigtable Row Key

`internal/bigtable/writer.go` writes one row per event:

```
{event_type}#{reverse_ts}#{event_id}     reverse_ts = math.MaxInt64 - event_unix_ms (>= 13 digits, 19 in practice)

event_data:raw               the validated JSON payload
metadata:<attribute>          one column per Pub/Sub attribute (event_type, event_id, timestamp)
processing_status:received_at / validated_at
```

The write is a conditional mutation on `event_data:raw`, so redelivering an event is a no-op. `scripts/seed_bigtable.py` writes the identical layout.

## Metrics

Exposed at `/metrics` (`internal/metrics/prometheus.go`): `ingestion_events_received_total{event_type}`, `ingestion_events_validated_total{event_type,result}`, `ingestion_events_failed_total{event_type,error_type}`, `ingestion_validation_latency_seconds{event_type}`, `ingestion_publish_latency_seconds{topic}`, `ingestion_bigtable_write_latency_seconds`.

## Local Development

```bash
# Start emulators
gcloud beta emulators pubsub start --project=test-project &
gcloud beta emulators bigtable start &

# Export emulator env vars
$(gcloud beta emulators pubsub env-init)
$(gcloud beta emulators bigtable env-init)

# Run the service
export PUBSUB_PROJECT_ID=test-project
export BIGTABLE_PROJECT_ID=test-project
export BIGTABLE_INSTANCE_ID=test-instance
go run ./cmd/server
```

## Testing

```bash
# Unit + contract tests (no emulators needed). The contract test validates
# every published sample payload against ../schemas/*.json.
go test ./internal/validator/... ./internal/handler/...

# Emulator-backed tests (skip automatically when the emulator variables are unset)
PUBSUB_EMULATOR_HOST=localhost:8085 go test ./internal/publisher/...
BIGTABLE_EMULATOR_HOST=localhost:8086 go test ./internal/bigtable/...

# All tests
go test ./...

# Benchmarks (same command as `make bench` at the repository root)
go test -bench=. -benchmem -run=^$ ./internal/validator/...
```

## Build

```bash
# Local binary
go build -o server ./cmd/server

# Docker
docker build -t ingestion-service .
docker run -p 8080:8080 ingestion-service
```
