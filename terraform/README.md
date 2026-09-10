# GCP Financial Data Platform - Terraform Infrastructure

Infrastructure-as-code for the GCP Financial Data Platform. Eight modules provision the cloud resources for the dev and prod environment roots. Every module passes `terraform fmt -check` and `terraform validate` in CI with the provider versions pinned in each module's `.terraform.lock.hcl`; nothing is applied from CI.

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
BigQuery (fdp_<env>_<layer>): raw --> staging --> marts_finance / marts_analytics
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

Provisions the analytical warehouse. Every dataset is `fdp_<env>_<layer>`, the same names dbt, the Airflow DAG and the governance service use:

| Dataset | Tables defined here | Purpose |
|---------|--------------------|---------|
| `fdp_<env>_raw` | `raw_revenue_transactions`, `raw_usage_metrics`, `raw_cost_records` | Landing tables: JSON Schema properties + `ingestion_timestamp`; MERGE target of the DAG, dbt `raw` source |
| `fdp_<env>_staging` | none (dbt views) | `stg_*` views that parse and dedupe the raw tables |
| `fdp_<env>_intermediate` | none | Intermediate models are ephemeral; dataset kept for ad-hoc use |
| `fdp_<env>_marts_finance` | `fct_*` shells | Revenue summaries, cost attribution, product-region breakdowns (dbt-built) |
| `fdp_<env>_marts_analytics` | `fct_*` shells | Customer usage reports, unit economics (dbt-built) |
| `fdp_<env>_audit` | `access_log`, `permission_changes`, `anomaly_alerts`, `pipeline_audit_log` | Audit trail; `anomaly_alerts` is written by the Airflow operator and shares its schema with `docs/data_model.md` |

`fdp_<env>_seeds` is created by `dbt seed`, `fdp_<env>_snapshots` by the disaster_recovery module.

Finance mart tables are partitioned by date and clustered by `product_line` and `region`. An authorized view sketches region-scoped analyst access. Note: the mart table shells declare a column set that differs from the dbt models that will `CREATE OR REPLACE` them; reconciling them is a documented follow-up.

### bigtable

Provisions a Bigtable instance for sub-10ms point reads of financial events. Column families are optimized for different access patterns:

- `event_data`: Primary payload, 90-day retention
- `metadata`: Ingestion lineage, single version
- `processing_status`: Processing history, 3 versions for debugging

An app profile enables single-row transactions for deduplication via check-and-mutate operations.

### pubsub

Provisions the event streaming backbone with exactly-once delivery and a dead-letter queue:

- Validated events topic (`financial-events-validated-<env>`); no topic schema on purpose -- the ingestion service enforces `schemas/*.json` and `modules/pubsub/README.md` explains why
- Dead-letter topic for failed messages (30-day retention)
- Exponential backoff retry policy (10s-600s), 5 delivery attempts before dead-lettering
- Message ordering enabled on the subscription

### gcs

Provisions object storage with a two-bucket architecture:

- **Raw bucket** (multi-region US): Active ingestion with versioning and Pub/Sub notifications
- **Backup bucket** (regional): 7-year lifecycle tiering (Standard -> Nearline -> Coldline -> Archive -> Delete)
- Daily cross-region replication via Storage Transfer at 03:00 UTC

### iam

Implements least-privilege access with 4 service accounts:

| Service Account | Permissions |
|----------------|-------------|
| `fdp-<env>-ingestion-sa` | Pub/Sub publisher, Bigtable user |
| `fdp-<env>-governance-sa` | BigQuery data viewer (audit only), job user |
| `fdp-<env>-airflow-sa` | Composer worker, BigQuery data editor (raw, staging, intermediate, marts), GCS object viewer |
| `fdp-<env>-dbt-sa` | BigQuery data viewer (raw), data editor (staging, intermediate, marts), job user |

Includes a custom `financial_auditor` role for compliance officers and Workload Identity bindings for the `data-services/ingestion-service` and `data-services/governance-service` Kubernetes service accounts created by the kubernetes module.

### kubernetes

Provisions a GKE Autopilot cluster and, in the `data-services` namespace, for each service a Workload-Identity-annotated Kubernetes service account, a Deployment and a ClusterIP Service:

- **ingestion-service** (port 8080, `/healthz` probes, HPA 2-10 replicas): env `PUBSUB_*` / `BIGTABLE_*` wired from the pubsub and bigtable modules
- **governance-service** (port 8081, `/healthz` probes): env `ENVIRONMENT`, `BIGQUERY_PROJECT_ID`, `BIGQUERY_DATASET_AUDIT` wired from the bigquery module

Images are `${artifact_registry_repo}/<service>:${image_tag}`, the path the CD workflow pushes (`ARTIFACT_REGISTRY_REPO/<service>:<short-sha>`); the repository itself is not created by Terraform. Egress network policies limit each pod to DNS and HTTPS; pod disruption budgets keep one pod of each service available during maintenance.

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

# Update terraform.tfvars with your project ID (optionally artifact_registry_repo / image_tag)
vim terraform.tfvars

terraform init          # local backend, no backend config needed
terraform plan
terraform apply
```

### Deploy Production Environment

```bash
cd terraform/environments/prod

# Create the state bucket first
gsutil mb -p YOUR_PROJECT_ID gs://YOUR_PROJECT_ID-terraform-state

# Update terraform.tfvars, then point the gcs backend at your bucket
vim terraform.tfvars
terraform init \
  -backend-config="bucket=YOUR_PROJECT_ID-terraform-state" \
  -backend-config="prefix=financial-data-platform/prod"

terraform plan -out=plan.tfplan
# Review the plan carefully before applying
terraform apply plan.tfplan
```

The CD workflow (`.github/workflows/cd.yml`) runs exactly these init/plan steps for the selected environment and uploads the plan; apply stays manual.

### Validate Locally

```bash
make tf-validate   # terraform init -backend=false + validate for every module
make tf-fmt        # terraform fmt -recursive terraform/
```

## Design Decisions

1. **Dataset-level IAM over table-level**: BigQuery dataset-level access is the narrowest practical scope when tables are managed by dbt. Table-level bindings don't scale with dynamic table creation.

2. **GKE Autopilot over Standard**: Eliminates node management overhead and provides per-pod billing. The trade-off (less control over node configuration) is acceptable for this workload profile.

3. **Exactly-once delivery in Pub/Sub**: Financial transactions cannot tolerate duplicates. The slight throughput reduction (~10-20%) is worth the data integrity guarantee.

4. **SSD over HDD for Bigtable**: Financial event lookups require sub-10ms latency. HDD would add 50-200ms per read, making it unsuitable for real-time fraud detection.

5. **Separate audit dataset**: Isolating audit data enables restrictive IAM (governance-sa gets read-only on audit, nothing else) and prevents accidental cross-contamination with business data.

6. **7-year backup retention**: Aligns with SOX record retention requirements. GDPR data subject deletion is handled at the object level, not the lifecycle level.
