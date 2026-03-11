# GCP Financial Data Platform - Terraform Infrastructure

Infrastructure-as-code for the GCP Financial Data Platform. This Terraform codebase provisions and manages all cloud resources across development and production environments.

## Architecture Overview

The platform follows a medallion (bronze/silver/gold) data architecture with event-driven ingestion:

```
External Sources
    |
    v
GCS (raw bucket) --> Pub/Sub notification --> Ingestion Service (GKE)
    |                                              |
    |                                              v
    |                                     Pub/Sub (validated events)
    |                                              |
    |                                              v
    |                                     Bigtable (low-latency lookups)
    |                                              |
    v                                              v
BigQuery: staging --> intermediate --> marts_finance / marts_analytics
                                              |
                                              v
                                      Audit dataset
```

Orchestration is handled by Cloud Composer (managed Airflow), which triggers dbt transformations and data quality checks.

## Directory Structure

```
terraform/
├── modules/                    # Reusable, environment-agnostic modules
│   ├── bigquery/              # Analytical warehouse (datasets, tables, views)
│   ├── bigtable/              # Low-latency event lookup store
│   ├── pubsub/                # Event streaming (topics, subscriptions, DLQ)
│   ├── gcs/                   # Object storage (raw data, backups, lifecycle)
│   ├── iam/                   # Service accounts, roles, Workload Identity
│   ├── kubernetes/            # GKE Autopilot cluster and workload deployments
│   ├── cloud_composer/        # Managed Airflow for pipeline orchestration
│   └── disaster_recovery/     # Snapshots, DR test scheduling, recovery docs
├── environments/
│   ├── dev/                   # Development environment configuration
│   │   ├── main.tf           # Module wiring with dev-appropriate values
│   │   ├── variables.tf      # Environment-specific variables
│   │   ├── versions.tf       # Provider version constraints
│   │   └── terraform.tfvars  # Variable values (update with your project ID)
│   └── prod/                  # Production environment configuration
│       ├── main.tf
│       ├── variables.tf
│       ├── versions.tf
│       └── terraform.tfvars
└── README.md
```

## Modules

### bigquery

Provisions the analytical data warehouse with 5 datasets following the dbt medallion pattern:

| Dataset | Purpose |
|---------|---------|
| `staging` | Landing zone for validated events with lineage columns |
| `intermediate` | Cleaned/joined data (internal to dbt, not analyst-facing) |
| `marts_finance` | Revenue summaries, cost attribution, product-region breakdowns |
| `marts_analytics` | Customer usage reports, unit economics |
| `audit` | Access logs, permission changes, anomaly alerts, pipeline runs |

Finance mart tables are partitioned by date and clustered by `product_line` and `region` for query cost optimization. An authorized view implements row-level security for region-scoped analyst access.

### bigtable

Provisions a Bigtable instance for sub-10ms point reads of financial events. Column families are optimized for different access patterns:

- `event_data`: Primary payload, 90-day retention
- `metadata`: Ingestion lineage, single version
- `processing_status`: Processing history, 3 versions for debugging

An app profile enables single-row transactions for deduplication via check-and-mutate operations.

### pubsub

Provisions the event streaming backbone with schema enforcement, exactly-once delivery, and a dead-letter queue:

- Validated events topic with Avro schema enforcement
- Dead-letter topic for failed messages (30-day retention)
- Exponential backoff retry policy (10s-600s)
- Message ordering by partition key for stateful processing

### gcs

Provisions object storage with a two-bucket architecture:

- **Raw bucket** (multi-region US): Active ingestion with versioning and Pub/Sub notifications
- **Backup bucket** (regional): 7-year lifecycle tiering (Standard -> Nearline -> Coldline -> Archive -> Delete)
- Daily cross-region replication via Storage Transfer at 03:00 UTC

### iam

Implements least-privilege access with 4 service accounts:

| Service Account | Permissions |
|----------------|-------------|
| `ingestion-sa` | Pub/Sub publisher, Bigtable user |
| `governance-sa` | BigQuery data viewer (audit only), job user |
| `airflow-sa` | Composer worker, BigQuery data editor, GCS object viewer |
| `dbt-sa` | BigQuery data editor (staging, intermediate, marts), job user |

Includes a custom `financial_auditor` role for compliance officers and Workload Identity bindings for GKE.

### kubernetes

Provisions a GKE Autopilot cluster with two microservices:

- **ingestion-service**: Validates and publishes financial events (HPA: 2-10 replicas)
- **governance-service**: Monitors access patterns and enforces data policies

Network policies restrict egress to only the GCP APIs each service needs. Pod disruption budgets ensure availability during maintenance.

### cloud_composer

Provisions a Composer 2 (managed Airflow) environment for pipeline orchestration. Automatically sized based on environment (small for dev, medium for prod). Includes dbt-bigquery and data processing PyPI packages.

### disaster_recovery

Implements the DR strategy with:

- Daily BigQuery dataset snapshots via Data Transfer Service
- Monthly DR test trigger via Cloud Scheduler
- Documented recovery procedure (RTO: 45 minutes, RPO: 1 hour)

## Getting Started

### Prerequisites

- Terraform >= 1.5
- Google Cloud SDK (`gcloud`) authenticated
- A GCP project with billing enabled
- Required APIs enabled: BigQuery, Bigtable, Pub/Sub, Cloud Storage, GKE, Composer, Cloud Scheduler, IAM

### Deploy Development Environment

```bash
cd terraform/environments/dev

# Update terraform.tfvars with your project ID
vim terraform.tfvars

terraform init
terraform plan
terraform apply
```

### Deploy Production Environment

```bash
cd terraform/environments/prod

# Create the state bucket first
gsutil mb -p YOUR_PROJECT_ID gs://YOUR_PROJECT_ID-terraform-state

# Update terraform.tfvars and backend bucket reference in main.tf
vim terraform.tfvars
vim main.tf

terraform init
terraform plan -out=plan.tfplan
# Review the plan carefully before applying
terraform apply plan.tfplan
```

## Design Decisions

1. **Dataset-level IAM over table-level**: BigQuery dataset-level access is the narrowest practical scope when tables are managed by dbt. Table-level bindings don't scale with dynamic table creation.

2. **GKE Autopilot over Standard**: Eliminates node management overhead and provides per-pod billing. The trade-off (less control over node configuration) is acceptable for this workload profile.

3. **Exactly-once delivery in Pub/Sub**: Financial transactions cannot tolerate duplicates. The slight throughput reduction (~10-20%) is worth the data integrity guarantee.

4. **SSD over HDD for Bigtable**: Financial event lookups require sub-10ms latency. HDD would add 50-200ms per read, making it unsuitable for real-time fraud detection.

5. **Separate audit dataset**: Isolating audit data enables restrictive IAM (governance-sa gets read-only on audit, nothing else) and prevents accidental cross-contamination with business data.

6. **7-year backup retention**: Aligns with SOX record retention requirements. GDPR data subject deletion is handled at the object level, not the lifecycle level.
