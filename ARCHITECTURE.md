# Architecture

This document provides a comprehensive walkthrough of the GCP Financial Data Platform architecture. It is structured for a 45-minute system design discussion -- start with the problem, walk through requirements, justify decisions, and address scaling and security.

---

## 1. Problem Statement

A growing AI company needs reliable financial data infrastructure to power revenue reporting, cost attribution, and business metrics. The system must:

- Handle multiple data sources with different schemas and cadences
- Enforce strict access controls so only authorized roles can see financial data
- Maintain complete audit trails for SOX and ITGC compliance
- Guarantee data durability -- revenue numbers feed financial reporting and board presentations
- Support both real-time queries (recent events) and batch analytics (daily reports)

Revenue accuracy directly impacts financial reporting, cost optimization decisions, and compliance obligations. A $1 discrepancy in automated reporting triggers manual reconciliation processes that cost orders of magnitude more in engineering time than preventing the discrepancy in the first place.

---

## 2. Requirements

### Functional

| Requirement | Implementation |
|-------------|---------------|
| Ingest financial events from multiple sources (billing, usage, cost) | Go ingestion service with typed JSON schema validation |
| Validate events against strict schemas before processing | JSON Schema Draft-07 with embedded schemas in the service binary |
| Transform raw data into reporting-ready datasets | dbt models: staging, intermediate, marts |
| Enforce role-based access controls on all data | FastAPI governance service with RBAC engine |
| Maintain complete audit trails of all data access | Append-only audit log (every check, grant, and revoke logged) |
| Generate daily financial reports (revenue, costs, usage) | Airflow DAG with dbt materializations and anomaly detection |
| Detect anomalies in financial data | Statistical outlier detection (2-sigma over 30-day lookback) |

### Non-Functional

| Requirement | Target | Justification |
|-------------|--------|---------------|
| Data durability | 99.99% | Financial records cannot be lost; feeds external reporting |
| Recovery Point Objective | <1 hour | Daily replication + Pub/Sub 7-day retention allows replay |
| Recovery Time Objective | <45 minutes | BigQuery snapshot restore is a metadata operation |
| Hot-path query latency | <1 minute | Recent event lookups via BigTable for operational dashboards |
| Batch pipeline freshness | <30 minutes | Daily pipeline runs at 02:00 UTC with 4-hour SLA |
| Audit trail retention | 7 years | SOX/ITGC compliance for financial records |
| Ingestion throughput | 10K+ events/second | Current load is ~100K events/day; headroom for 100x growth |

---

## 3. Architecture Overview

<p align="center">
  <img src="docs/images/architecture.png" alt="Architecture Overview" width="100%">
</p>

---

## 4. Data Flow

**End-to-end walkthrough: "A customer makes an API call that generates revenue."**

### Step 1: Event Generation
The billing system generates a revenue transaction event when a customer's API call is metered and billed. The event contains: `transaction_id` (UUID), `timestamp` (ISO 8601), `amount_cents` (integer -- never floating point for money), `currency` (ISO 4217), `customer_id`, `product_line`, and `region`.

### Step 2: Ingestion (Write Path)
The event is POSTed to `POST /api/v1/events` on the Go ingestion service. The chi router handles request parsing, timeout enforcement (60s), and structured logging via zerolog.

### Step 3: Schema Validation
The validator loads JSON Schema Draft-07 definitions at startup and validates the event payload. It determines the event type from the payload structure (presence of `transaction_id` vs `metric_id` vs `record_id`) and applies the corresponding schema. Validation includes type checking, required field enforcement, enum value validation, and format verification (UUID, date-time, currency codes).

### Step 4: Routing
- **Valid events**: Published to the `financial-events-validated` Pub/Sub topic with the event type as a message attribute, AND written to BigTable for hot-path queries. The dual write ensures both real-time access and durable event storage.
- **Invalid events**: Published to the `financial-events-dead-letter` Pub/Sub topic with the validation error details attached as message attributes. Nothing is silently dropped.

### Step 5: Hot Path (BigTable)
The BigTable writer uses the event ID as the row key (ensuring idempotent writes) and stores the full event payload in a single column family. Row keys are prefixed with the event type for efficient scans. This enables sub-second lookups of recent events for operational dashboards and debugging.

### Step 6: Batch Ingestion (Airflow)
The `financial_pipeline_daily` DAG triggers at 02:00 UTC. First, a freshness check ensures the staging tables have been updated within the last 24 hours. Then, the `load_to_staging` task pulls messages from the Pub/Sub subscription and executes a `MERGE` query per event type into BigQuery staging tables. The MERGE deduplicates by event ID, ensuring exactly-once semantics even if messages are delivered multiple times.

### Step 7: dbt Transformations
Three transformation layers execute sequentially:

1. **Staging** (`stg_*`): Deduplication, type casting (ISO 8601 strings to TIMESTAMP), surrogate key generation, source system tagging.
2. **Intermediate** (`int_*`): Business logic -- currency conversion using seed exchange rates, daily revenue aggregation, customer usage rollups, cost center allocation.
3. **Marts** (`fct_*`): Reporting-ready tables -- daily revenue summary with DoD/WoW growth rates and MTD running totals, monthly cost attribution with category breakdown, unit economics with gross margin calculation.

### Step 8: Data Quality
dbt tests run after transformations: `not_null`, `unique`, `accepted_values`, `relationships` (referential integrity), and three custom tests (`assert_revenue_non_negative`, `assert_no_orphan_transactions`, `assert_date_completeness`).

### Step 9: Anomaly Detection
The custom `AnomalyDetectionOperator` queries the `fct_daily_revenue_summary` mart, computes a 30-day rolling mean and standard deviation per product line/region, and flags any day where revenue falls outside 2 standard deviations. Alerts are written to `audit.anomaly_alerts`.

### Step 10: Access Control (Read Path)
When a user or service queries a mart, the governance service evaluates the request against the RBAC permission matrix. The engine iterates through the role's dataset patterns (e.g., `marts_finance.*`) and returns GRANTED on first glob match with the requested permission. Every access check -- both granted and denied -- is logged to the audit trail with user ID, dataset, permission, IP address, user agent, and matched pattern.

---

## 5. Key Design Decisions

### 5.1 BigTable for Hot Path (vs Redis)

**Context**: The system needs sub-second lookups of recent events for operational dashboards and incident debugging. The hot-path store must be durable and consistent.

**Decision**: BigTable with SSD storage and auto-scaling.

**Tradeoff**: BigTable has higher per-read latency (~5-10ms) compared to Redis (~1ms), but provides strong durability guarantees without additional replication configuration. At 10K events/second, the latency difference is negligible for dashboard use cases.

**Alternatives Considered**:
- **Redis**: Faster reads, but requires Redis Sentinel or Redis Cluster for HA, and persistence configuration (RDB/AOF) introduces complexity. For financial data, losing even a few seconds of events during a Redis failover is unacceptable.
- **Memorystore (managed Redis)**: Better operational story, but still requires separate backup/replication and does not integrate with GCP IAM as naturally.
- **Firestore**: Document model is a good fit, but throughput limits (10K writes/sec per database) make it a bottleneck at scale.

### 5.2 Cloud Composer vs Self-Managed Airflow

**Context**: The batch pipeline needs reliable orchestration with task dependencies, retries, SLA monitoring, and a web UI for observability.

**Decision**: Cloud Composer (managed Airflow) for production, docker-compose Airflow for local development.

**Tradeoff**: Composer costs ~$400/month for a small environment vs ~$150/month for self-managed on GKE. The $250/month premium buys: managed upgrades, automatic scaling of Airflow workers, integrated monitoring, and elimination of Airflow-specific operational burden.

**Alternatives Considered**:
- **Self-managed Airflow on GKE**: Full control, but requires managing the scheduler, webserver, metadata database, and worker autoscaling. The team's time is better spent on DAG logic.
- **Cloud Workflows**: Simpler and cheaper, but lacks the DAG visualization, complex dependency management, and SLA monitoring that Airflow provides.
- **Prefect / Dagster**: Modern alternatives with better developer experience, but smaller community in the GCP ecosystem and less mature managed offerings.

### 5.3 dbt vs Raw SQL / Spark SQL

**Context**: Raw financial data needs to be transformed into reporting-ready datasets with testable business logic.

**Decision**: dbt with BigQuery adapter.

**Tradeoff**: dbt adds a build step and requires learning its Jinja-SQL dialect. But the benefits are substantial: every model is version-controlled, tested, and documented in one place. The ref() function creates an explicit DAG of dependencies, and `dbt docs generate` produces interactive lineage documentation for free.

**Alternatives Considered**:
- **Raw SQL scripts**: No dependency management, no built-in testing, no documentation generation. Works for 5 queries; falls apart at 50.
- **Spark SQL / Dataproc**: Overkill for the current data volume (~1TB). Spark's distributed processing adds latency and cost for datasets that BigQuery handles in seconds.
- **Dataform (Google-native dbt)**: Tighter BigQuery integration, but smaller community, fewer packages, and less portable if the company ever moves off GCP.

### 5.4 RBAC vs ABAC

**Context**: Financial data access must be controlled, audited, and explainable to compliance auditors.

**Decision**: Role-Based Access Control with glob-pattern dataset matching.

**Tradeoff**: RBAC cannot express conditions like "analyst can only read data during business hours" or "access restricted to VPN IP ranges." These are ABAC concerns that would require a policy engine (like OPA/Rego). Starting with RBAC means:
- The permission model fits on a single screen (5 roles, ~10 patterns)
- Audit logs are trivially interpretable ("analyst-001 was GRANTED read on marts_finance.* because they have the finance_analyst role matching pattern marts_finance.*")
- Migration to ABAC is additive -- we add attribute checks around the existing role check, not replace it

**Alternatives Considered**:
- **ABAC with OPA**: More expressive, but the policy language (Rego) adds cognitive load and the policy evaluation latency can be non-trivial for high-volume access checks.
- **Google IAM only**: Would work for BigQuery-level access, but does not provide application-level audit logging or the ability to enforce fine-grained dataset-level permissions without one IAM binding per table.

### 5.5 Cross-Region GCS Replication vs Multi-Region Bucket

**Context**: Financial data must survive a full regional outage with verifiable backup integrity.

**Decision**: Explicit cross-region replication via Storage Transfer Service from a multi-region raw bucket to a single-region backup bucket.

**Tradeoff**: This requires a daily transfer job (03:00 UTC) and lifecycle management configuration. Multi-region buckets handle this transparently. However:
- We can verify replication by comparing object counts and checksums between buckets
- We control the replication schedule to avoid contention with peak ingestion
- The backup bucket has its own lifecycle policy (Standard -> Nearline -> Coldline -> Archive -> Delete) optimized for cost, not access speed
- In a compliance audit, we can demonstrate exactly when and how data is replicated

**Alternatives Considered**:
- **Multi-region bucket**: Simpler configuration, but replication is opaque. GCP guarantees durability, but we cannot independently verify replication timing or completeness.
- **Dual-region bucket**: Compromise between multi-region and explicit replication, but still opaque and does not support the lifecycle tiering strategy needed for 7-year retention cost optimization.

---

## 6. Scaling Considerations

### Current State: ~100K events/day (~1.2 events/sec average)

The system is provisioned for 10K events/sec burst capacity. At current load, all components are significantly underutilized, which is intentional -- the architecture is designed for the next two orders of magnitude.

### 10x: 1M events/day (~12 events/sec average, 100K/sec burst)

| Component | Change Required |
|-----------|----------------|
| BigTable | Add nodes via auto-scaling (currently 1 node, scales to 10+) |
| Pub/Sub | No change (automatic throughput scaling) |
| Ingestion Service | Add GKE replicas (horizontal pod autoscaler) |
| Airflow | Add workers, increase task parallelism |
| BigQuery | No change (on-demand pricing scales automatically) |
| dbt | No change (BigQuery handles the compute) |

**Architecture changes**: None. All components scale horizontally within their current configuration.

### 100x: 10M events/day (~120 events/sec average, 1M/sec burst)

| Component | Change Required |
|-----------|----------------|
| Pub/Sub | Partition by event type (3 topics instead of 1) |
| Airflow | Replace batch Pub/Sub pull with Dataflow streaming pipeline |
| BigQuery | Consider streaming inserts instead of batch MERGE |
| BigTable | Multi-cluster replication for read scaling |
| Ingestion Service | Connection pooling, batch Pub/Sub publishing |

**Architecture changes**: The batch Pub/Sub pull becomes a bottleneck. Introduce Dataflow for streaming transformations that write directly to BigQuery staging tables in near real-time. The Airflow DAG becomes an orchestrator for dbt only, not data movement.

### 1000x: 100M events/day (~1200 events/sec average, 10M/sec burst)

| Component | Change Required |
|-----------|----------------|
| Pub/Sub | Replace with Kafka for higher throughput and consumer group management |
| BigTable | Replace with Spanner for global consistency and SQL query support |
| BigQuery | Slot reservations, BI Engine for sub-second dashboard queries |
| Ingestion Service | Move to gRPC, implement backpressure, circuit breakers |
| dbt | Incremental models with merge keys instead of full table rebuilds |

**Architecture changes**: Significant evolution. Event sourcing pattern with Kafka as the system of record. Spanner replaces BigTable for both hot-path and transactional queries. The ingestion service becomes a Kafka producer, and separate Kafka consumers handle BigQuery loading, real-time alerting, and downstream system notifications.

---

## 7. Security Model

### Data Classification

| Tier | Classification | Examples | Access |
|------|---------------|----------|--------|
| 1 | Public | Aggregated metrics, anonymized usage stats | Executive, Analyst |
| 2 | Internal | Intermediate models, cost center rollups | Data Engineer, Analyst |
| 3 | Confidential | Raw transactions, customer IDs, PII | Admin only (with audit) |

### Encryption

| Layer | Method | Key Management |
|-------|--------|---------------|
| At rest | AES-256 (GCP default) | Google-managed keys (CMEK available for Tier 3) |
| In transit | TLS 1.3 | Managed certificates |
| Application | Field-level encryption for Tier 3 PII | Cloud KMS with envelope encryption |

### IAM

- **Least privilege**: Every service account has the minimum permissions needed. The ingestion service can publish to Pub/Sub and write to BigTable, but cannot read from BigQuery.
- **Service accounts per service**: `ingestion-sa`, `governance-sa`, `composer-sa`, `dbt-sa`. No shared credentials.
- **Workload Identity**: GKE pods authenticate via Workload Identity Federation -- no JSON key files in the environment. The Terraform IAM module configures the bindings.
- **Custom roles**: Where predefined roles are too broad (e.g., `roles/bigquery.dataViewer` grants read to ALL datasets), custom roles scope access to specific datasets.
- **No primitive roles**: The IAM sync validation rejects `roles/owner`, `roles/editor`, and `roles/viewer`.

### Audit

- **Every data access logged**: Both granted and denied access checks are recorded with user ID, dataset, permission, IP address, user agent, and matched RBAC pattern.
- **Permission changes tracked**: Every grant and revoke includes the admin who made the change, the reason, and a timestamp.
- **7-year retention**: Audit tables in BigQuery are append-only with no delete permissions granted to any service account.
- **Immutable**: BigQuery audit tables use table-level IAM to prevent modifications. Only the governance service account can INSERT.
- **Pipeline audit**: Every Airflow DAG run records its execution metadata, records processed, and final status.

### Network

- **Private GKE nodes**: Nodes have private IP addresses only. The API server is accessible via authorized networks.
- **VPC Service Controls**: BigQuery, GCS, and Pub/Sub are inside a service perimeter. Requests from outside the perimeter are denied.
- **Cloud NAT**: Egress traffic from private nodes routes through Cloud NAT with static IP addresses for allowlisting by external partners.
- **Internal load balancing**: The governance service is only accessible within the VPC. External access goes through Cloud Armor WAF.

---

## 8. Cost Analysis

Estimated monthly GCP cost at current scale (100K events/day):

| Service | Configuration | Monthly Cost |
|---------|--------------|--------------|
| BigTable | 1 node, SSD, ~100GB storage | ~$500 |
| BigQuery | 5 datasets, ~1TB storage, ~10TB queries/month | ~$80 |
| Pub/Sub | ~3M messages/month, 2 topics + subscriptions | ~$15 |
| GCS | 500GB raw + 500GB backup (with lifecycle tiering) | ~$25 |
| Cloud Composer | Small environment (1 scheduler, 2 workers) | ~$400 |
| GKE Autopilot | 2 services, low traffic baseline | ~$150 |
| Cloud NAT | Low egress volume | ~$30 |
| Monitoring | Prometheus metrics, Cloud Logging | ~$20 |
| **Total** | | **~$1,220/month** |

### Cost Optimization Strategies

| Strategy | Savings | When to Apply |
|----------|---------|---------------|
| BigQuery slot reservations | 30-50% on query costs | When monthly query spend exceeds $500 |
| BigTable auto-scaling | 40-60% on node costs | Already configured; savings during off-peak hours |
| GCS lifecycle policies | 70-80% on archive storage | Already configured; savings compound over years |
| Composer environment right-sizing | 20-30% | After 3 months of DAG performance data |
| Committed Use Discounts (CUD) | 25-55% on compute | After 6 months of stable baseline |
| BigQuery BI Engine | Reduce repeated query costs | When dashboard query volume exceeds 100/day |

---

## 9. Observability

### Metrics (Prometheus)

The ingestion service exposes four metric families at `/metrics`:

| Metric | Type | Description |
|--------|------|-------------|
| `events_received_total` | Counter | Total events received, labeled by event type and status |
| `events_validated_total` | Counter | Validation results, labeled by event type and result |
| `event_processing_duration_seconds` | Histogram | End-to-end processing latency |
| `pubsub_publish_duration_seconds` | Histogram | Pub/Sub publish latency |

### Alerting Thresholds

| Alert | Threshold | Severity | Action |
|-------|-----------|----------|--------|
| Ingestion latency p99 | >500ms | Warning | Check BigTable writer |
| DLQ message rate | >1% of total | Critical | Schema change or upstream issue |
| Airflow DAG failure | Any task failure | Critical | Check task logs, retry |
| BigQuery freshness | >24h stale | Warning | Check Airflow scheduler |
| Anomaly detection | >2 sigma | Warning | Review in dashboard |
| Pub/Sub backlog | >10K unacked | Critical | Consumer health check |

---

## 10. Future Enhancements

1. **Streaming transforms** (Dataflow): Replace batch Pub/Sub pull with streaming pipeline for near real-time BigQuery updates.
2. **ABAC**: Add attribute-based conditions (time-of-day, IP range, data classification) to the RBAC engine.
3. **Data Catalog**: Integrate with Google Data Catalog for automated metadata discovery and data lineage visualization.
4. **ML pipeline**: Add Vertex AI pipeline for revenue forecasting using the `fct_daily_revenue_summary` mart as training data.
5. **Multi-region active-active**: Replicate the full stack to a second region for zero-RPO disaster recovery.
6. **Change Data Capture**: Add CDC from source systems for real-time data synchronization instead of batch pulls.
