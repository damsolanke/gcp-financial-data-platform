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
| GET    | /healthz          | Health check with dependency status  |
| GET    | /metrics          | Prometheus metrics                   |

### POST /api/v1/events

Accepts event type via query parameter `?type=revenue_transaction` or as a JSON field `event_type`.

**Supported event types:** `revenue_transaction`, `usage_metric`, `cost_record`

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
| `PUBSUB_TOPIC_VALIDATED`| `validated-events` | Topic for validated events        |
| `PUBSUB_TOPIC_DLQ`      | `dlq-events`       | Topic for failed events           |
| `BIGTABLE_PROJECT_ID`   | -                  | GCP project for Bigtable          |
| `BIGTABLE_INSTANCE_ID`  | -                  | Bigtable instance ID              |
| `BIGTABLE_TABLE_ID`     | `events`           | Bigtable table name               |

Emulator auto-detection: set `PUBSUB_EMULATOR_HOST` and/or `BIGTABLE_EMULATOR_HOST` for local development.

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
# Unit tests (no emulators needed)
go test ./internal/validator/... ./internal/handler/...

# Integration tests (requires emulators)
PUBSUB_EMULATOR_HOST=localhost:8085 go test ./internal/publisher/...
BIGTABLE_EMULATOR_HOST=localhost:8086 go test ./internal/bigtable/...

# All tests
go test ./...

# Benchmarks
go test -bench=. ./internal/validator/...
```

## Build

```bash
# Local binary
go build -o server ./cmd/server

# Docker
docker build -t ingestion-service .
docker run -p 8080:8080 ingestion-service
```
