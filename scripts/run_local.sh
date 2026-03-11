#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Set up local development environment with GCP emulators
#
# This script:
#   1. Starts docker-compose services (Pub/Sub emulator, BigTable emulator,
#      Postgres, Airflow, ingestion-service, governance-service).
#   2. Waits for emulators to be healthy.
#   3. Creates Pub/Sub topics and subscriptions.
#   4. Creates the BigTable table and column families.
#   5. Generates sample data and seeds BigTable.
#   6. Prints service URLs.
#
# Usage:
#   ./scripts/run_local.sh           # Full setup
#   ./scripts/run_local.sh --skip-data  # Skip data generation & seeding
#   ./scripts/run_local.sh --down       # Tear down all services
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

PROJECT_ID="local-project"
PUBSUB_EMULATOR_HOST="localhost:8085"
BIGTABLE_EMULATOR_HOST="localhost:8086"
BIGTABLE_INSTANCE_ID="financial-events"
BIGTABLE_TABLE_ID="events"

# Pub/Sub topics and their subscriptions
PUBSUB_TOPICS=(
    "financial-events-raw"
    "financial-events-validated"
    "financial-events-dead-letter"
    "financial-events-revenue"
    "financial-events-usage"
    "financial-events-costs"
)

PUBSUB_SUBSCRIPTIONS=(
    "financial-events-raw:ingestion-raw-sub"
    "financial-events-validated:processing-validated-sub"
    "financial-events-dead-letter:dlq-monitor-sub"
    "financial-events-revenue:revenue-sub"
    "financial-events-usage:usage-sub"
    "financial-events-costs:costs-sub"
)

# BigTable column families
BIGTABLE_COLUMN_FAMILIES=(
    "event_data"
    "metadata"
    "processing_status"
)

# ---------------------------------------------------------------------------
# Colours for output
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}==> $*${NC}\n"; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

SKIP_DATA=false
TEARDOWN=false

for arg in "$@"; do
    case "${arg}" in
        --skip-data)  SKIP_DATA=true  ;;
        --down)       TEARDOWN=true   ;;
        --help|-h)
            echo "Usage: $0 [--skip-data] [--down] [--help]"
            echo ""
            echo "  --skip-data   Skip sample data generation and BigTable seeding"
            echo "  --down        Tear down all Docker Compose services"
            echo "  --help, -h    Show this help message"
            exit 0
            ;;
        *)
            error "Unknown argument: ${arg}"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

if [[ "${TEARDOWN}" == "true" ]]; then
    header "Tearing down services"
    docker compose down --remove-orphans
    success "All services stopped."
    exit 0
fi

# ---------------------------------------------------------------------------
# Start services
# ---------------------------------------------------------------------------

header "Starting Docker Compose services"
docker compose up -d --build
success "Docker Compose services starting."

# ---------------------------------------------------------------------------
# Wait for emulators to be healthy
# ---------------------------------------------------------------------------

wait_for_service() {
    local name="$1"
    local check_cmd="$2"
    local max_retries="${3:-30}"
    local retry_interval="${4:-2}"

    info "Waiting for ${name} ..."
    local attempt=0
    while [[ ${attempt} -lt ${max_retries} ]]; do
        if eval "${check_cmd}" > /dev/null 2>&1; then
            success "${name} is healthy."
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "${retry_interval}"
    done

    error "${name} did not become healthy after $((max_retries * retry_interval))s"
    return 1
}

header "Waiting for emulators"

wait_for_service \
    "Pub/Sub emulator" \
    "curl -sf http://${PUBSUB_EMULATOR_HOST}" \
    30 2

wait_for_service \
    "BigTable emulator" \
    "nc -z localhost 8086" \
    30 2

wait_for_service \
    "PostgreSQL" \
    "docker compose exec -T postgres pg_isready -U airflow" \
    30 2

# ---------------------------------------------------------------------------
# Create Pub/Sub topics and subscriptions
# ---------------------------------------------------------------------------

header "Setting up Pub/Sub topics and subscriptions"

export PUBSUB_EMULATOR_HOST

python3 - "${PROJECT_ID}" <<'PYEOF'
"""Create Pub/Sub topics and subscriptions on the emulator."""
import sys
import os

project_id = sys.argv[1]

try:
    from google.cloud import pubsub_v1
except ImportError:
    print("ERROR: google-cloud-pubsub not installed. Run: pip install google-cloud-pubsub")
    sys.exit(1)

publisher = pubsub_v1.PublisherClient()
subscriber = pubsub_v1.SubscriberClient()

# Topics
topics = [
    "financial-events-raw",
    "financial-events-validated",
    "financial-events-dead-letter",
    "financial-events-revenue",
    "financial-events-usage",
    "financial-events-costs",
]

for topic_name in topics:
    topic_path = publisher.topic_path(project_id, topic_name)
    try:
        publisher.create_topic(request={"name": topic_path})
        print(f"  Created topic: {topic_name}")
    except Exception as exc:
        if "already exists" in str(exc).lower() or "409" in str(exc):
            print(f"  Topic exists:  {topic_name}")
        else:
            print(f"  WARNING creating topic {topic_name}: {exc}")

# Subscriptions (topic:subscription pairs)
subscriptions = [
    ("financial-events-raw", "ingestion-raw-sub"),
    ("financial-events-validated", "processing-validated-sub"),
    ("financial-events-dead-letter", "dlq-monitor-sub"),
    ("financial-events-revenue", "revenue-sub"),
    ("financial-events-usage", "usage-sub"),
    ("financial-events-costs", "costs-sub"),
]

for topic_name, sub_name in subscriptions:
    topic_path = publisher.topic_path(project_id, topic_name)
    sub_path = subscriber.subscription_path(project_id, sub_name)
    try:
        subscriber.create_subscription(
            request={"name": sub_path, "topic": topic_path}
        )
        print(f"  Created subscription: {sub_name} -> {topic_name}")
    except Exception as exc:
        if "already exists" in str(exc).lower() or "409" in str(exc):
            print(f"  Subscription exists:  {sub_name}")
        else:
            print(f"  WARNING creating subscription {sub_name}: {exc}")

print("\n  Pub/Sub setup complete.")
PYEOF

success "Pub/Sub topics and subscriptions ready."

# ---------------------------------------------------------------------------
# Create BigTable table and column families
# ---------------------------------------------------------------------------

header "Setting up BigTable table"

export BIGTABLE_EMULATOR_HOST

python3 - "${PROJECT_ID}" "${BIGTABLE_INSTANCE_ID}" "${BIGTABLE_TABLE_ID}" <<'PYEOF'
"""Create BigTable table and column families on the emulator."""
import sys

project_id = sys.argv[1]
instance_id = sys.argv[2]
table_id = sys.argv[3]

try:
    from google.cloud import bigtable
    from google.cloud.bigtable import column_family as cf_module
except ImportError:
    print("ERROR: google-cloud-bigtable not installed. Run: pip install google-cloud-bigtable")
    sys.exit(1)

client = bigtable.Client(project=project_id, admin=True)
instance = client.instance(instance_id)
table = instance.table(table_id)

column_families = ["event_data", "metadata", "processing_status"]
gc_rule = cf_module.MaxVersionsGCRule(1)

# Check if table exists
try:
    existing_cfs = set(table.list_column_families().keys())
    print(f"  Table '{table_id}' already exists with families: {sorted(existing_cfs)}")

    # Add missing column families
    for cf_name in column_families:
        if cf_name not in existing_cfs:
            cf = table.column_family(cf_name, gc_rule=gc_rule)
            cf.create()
            print(f"  Created column family: {cf_name}")
except Exception:
    # Table does not exist -- create it
    print(f"  Creating table '{table_id}' ...")
    cf_spec = {cf: gc_rule for cf in column_families}
    table.create(column_families=cf_spec)
    print(f"  Created table with column families: {column_families}")

print("\n  BigTable setup complete.")
PYEOF

success "BigTable table and column families ready."

# ---------------------------------------------------------------------------
# Generate sample data and seed BigTable
# ---------------------------------------------------------------------------

if [[ "${SKIP_DATA}" == "true" ]]; then
    warn "Skipping data generation (--skip-data)."
else
    header "Generating sample data"
    python3 "${PROJECT_ROOT}/scripts/generate_sample_data.py" \
        --seed 42 \
        --output-dir "${PROJECT_ROOT}/data"
    success "Sample data generated."

    header "Seeding BigTable emulator"
    python3 "${PROJECT_ROOT}/scripts/seed_bigtable.py" \
        --input-dir "${PROJECT_ROOT}/data"
    success "BigTable seeded."
fi

# ---------------------------------------------------------------------------
# Wait for application services
# ---------------------------------------------------------------------------

header "Waiting for application services"

wait_for_service \
    "Ingestion service (port 8080)" \
    "curl -sf http://localhost:8080/healthz" \
    30 3 || warn "Ingestion service not healthy (may still be building)."

wait_for_service \
    "Governance service (port 8081)" \
    "curl -sf http://localhost:8081/healthz" \
    30 3 || warn "Governance service not healthy (may still be building)."

wait_for_service \
    "Airflow webserver (port 8082)" \
    "curl -sf http://localhost:8082/health" \
    60 3 || warn "Airflow webserver not healthy (may still be initialising)."

# ---------------------------------------------------------------------------
# Print service URLs
# ---------------------------------------------------------------------------

header "Local development environment is ready!"

echo -e "${BOLD}Service URLs:${NC}"
echo ""
echo -e "  ${CYAN}Ingestion Service${NC}     http://localhost:8080"
echo -e "  ${CYAN}  Health check${NC}        http://localhost:8080/healthz"
echo ""
echo -e "  ${CYAN}Governance Service${NC}    http://localhost:8081"
echo -e "  ${CYAN}  Health check${NC}        http://localhost:8081/healthz"
echo ""
echo -e "  ${CYAN}Airflow Webserver${NC}     http://localhost:8082"
echo -e "  ${CYAN}  Credentials${NC}         admin / admin"
echo ""
echo -e "  ${CYAN}Pub/Sub Emulator${NC}      ${PUBSUB_EMULATOR_HOST}"
echo -e "  ${CYAN}BigTable Emulator${NC}     ${BIGTABLE_EMULATOR_HOST}"
echo -e "  ${CYAN}PostgreSQL${NC}            localhost:5432 (airflow/airflow)"
echo ""
echo -e "${BOLD}Environment variables for local clients:${NC}"
echo ""
echo "  export PUBSUB_EMULATOR_HOST=${PUBSUB_EMULATOR_HOST}"
echo "  export BIGTABLE_EMULATOR_HOST=${BIGTABLE_EMULATOR_HOST}"
echo "  export GCP_PROJECT_ID=${PROJECT_ID}"
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo ""
echo "  make logs             # Tail all service logs"
echo "  make down             # Stop all services"
echo "  make generate         # Regenerate sample data"
echo "  make test             # Run all tests"
echo ""
