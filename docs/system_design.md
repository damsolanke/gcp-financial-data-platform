# System Design -- Interview Walkthrough

This is the condensed version of [ARCHITECTURE.md](../ARCHITECTURE.md), structured for a 45-minute system design discussion. Each section includes talking points and anticipated follow-up questions.

---

## Opening (2 minutes)

> "I built a production-grade financial data platform on GCP that handles event ingestion, batch transformations, access control, and disaster recovery. The system processes financial events from billing, usage tracking, and cost allocation systems, transforms them into reporting-ready datasets, and enforces RBAC with full audit trails for SOX compliance."

**Key numbers to mention upfront:**
- 10K events/sec ingestion throughput
- <45 minute RTO, <1 hour RPO
- 7-year audit trail retention
- 5 roles, 5 fact tables, 7 Terraform modules

---

## Problem and Requirements (5 minutes)

### The Problem
An AI company needs reliable financial data infrastructure. Revenue accuracy feeds board reporting, cost attribution drives optimization decisions, and compliance (SOX/ITGC) requires auditable data access.

### Talking Points
- "Financial data has zero tolerance for data loss. A $1 discrepancy triggers manual reconciliation that costs 100x more in engineering time."
- "The system serves three distinct consumers: real-time dashboards (ops team needs recent events fast), daily reports (finance team needs aggregated metrics), and compliance (auditors need who accessed what, when, and why)."
- "These three consumer patterns drove the three-path architecture: write path, batch path, read path."

### Likely Follow-Up
**Q: Why not just use BigQuery for everything?**
A: BigQuery is excellent for analytics but has minimum 1-second query latency and is not designed for point lookups. Operational dashboards need sub-second access to recent events, which BigTable provides. BigQuery handles the batch analytics where latency tolerance is 30+ minutes.

---

## Architecture Walkthrough (15 minutes)

### Write Path: Go Ingestion Service

```
Event Source -> POST /api/v1/events -> Schema Validation -> Valid: Pub/Sub + BigTable
                                                         -> Invalid: Dead Letter Queue
```

**Talking Points:**
- "Go was chosen for the ingestion service because of its low memory footprint, excellent concurrency model (goroutines for dual-write fanout), and fast startup time for GKE pod scaling."
- "Schema validation happens at the edge, before any data is persisted. This is the cheapest place to catch bad data."
- "The dual write to Pub/Sub AND BigTable is intentional -- Pub/Sub is the durable transport for batch processing, BigTable is the hot-path store for real-time queries. They serve different access patterns."
- "Invalid events go to a dead-letter queue with error details attached. Nothing is silently dropped."

**Likely Follow-Up:**
- **Q: What happens if the BigTable write fails but Pub/Sub succeeds?** A: The event is still durably stored in Pub/Sub. BigTable is an optimization for real-time queries, not the system of record. The batch pipeline will pick up the event from Pub/Sub regardless.
- **Q: How do you handle schema evolution?** A: JSON Schema Draft-07 supports `additionalProperties: false`, so new fields require a schema update. Schema changes are versioned alongside the code, and the CI pipeline validates that schemas parse correctly.

### Batch Path: Airflow + dbt

```
Pub/Sub -> Airflow DAG (02:00 UTC) -> MERGE into staging -> dbt run (staging -> intermediate -> marts) -> dbt test -> Reports + Anomaly Detection
```

**Talking Points:**
- "The DAG runs daily at 02:00 UTC with a 4-hour SLA. The MERGE operation provides exactly-once semantics -- if the same event arrives twice (Pub/Sub at-least-once delivery), the MERGE deduplicates on the event ID."
- "dbt enforces a three-layer transformation pattern. Staging handles deduplication and type casting. Intermediate handles business logic like currency conversion and aggregation. Marts are the reporting-ready tables that users query."
- "Every dbt model is tested. The staging layer has 40+ tests including not_null, unique, accepted_values, and referential integrity. Custom tests assert revenue non-negativity, no orphan transactions, and date completeness."

**Likely Follow-Up:**
- **Q: Why daily and not streaming?** A: The business requirements are daily financial reports. Streaming would add complexity (Dataflow, watermarking, late data handling) for no user-facing benefit. When the business needs intra-day reporting, we add a Dataflow streaming pipeline that writes to BigQuery -- the dbt models work unchanged.
- **Q: How do you handle late-arriving data?** A: The MERGE operation is idempotent. If an event arrives after the daily pipeline runs, it will be picked up in the next day's run. The staging tables use `ingestion_timestamp` for freshness monitoring, not the event timestamp.

### Read Path: Governance Service

```
User/Service -> GET /api/v1/access/check/{user_id}/{dataset_id} -> RBAC Engine -> GRANTED/DENIED + Audit Log
```

**Talking Points:**
- "Every data access is evaluated against a permission matrix: role -> dataset pattern -> permissions. The engine uses glob matching (e.g., `marts_finance.*` matches `marts_finance.fct_daily_revenue_summary`)."
- "Every access check is logged, including denied requests. The audit log captures user ID, dataset, permission, IP address, user agent, and the matched RBAC pattern."
- "The IAM sync service translates the application RBAC matrix into GCP IAM bindings. This ensures BigQuery-level permissions always match the application layer."

**Likely Follow-Up:**
- **Q: Why not use GCP IAM directly?** A: GCP IAM does not provide application-level audit logging with the detail we need (matched pattern, request reason, session context). Also, GCP IAM operates at the dataset level -- our RBAC supports table-level patterns within datasets.
- **Q: How does this scale with more roles?** A: The RBAC matrix is O(roles * patterns) which is small. The real scaling concern is the audit log volume -- at 1000 access checks/second, that is 2.6B rows/year. BigQuery handles this with date partitioning and time-based retention.

---

## Data Model (5 minutes)

### Three Event Types
| Event | Source | Key Fields |
|-------|--------|-----------|
| Revenue Transaction | Billing system | `transaction_id`, `amount_cents`, `currency`, `customer_id`, `product_line`, `region` |
| Usage Metric | Usage tracking | `metric_id`, `metric_type` (api_calls, tokens_processed, compute_hours), `quantity`, `unit` |
| Cost Record | Cost allocation | `record_id`, `cost_center`, `category` (compute, storage, network, personnel), `amount_cents` |

### dbt Model Lineage
```
staging           intermediate           marts
--------          ------------           -----
stg_revenue   --> int_daily_revenue  --> fct_daily_revenue_summary
                                     --> fct_revenue_by_product_region

stg_usage     --> int_customer_usage --> fct_customer_usage_report

stg_cost      --> int_cost_by_center --> fct_monthly_cost_attribution

(cross-model join)                   --> fct_unit_economics
```

**Talking Point:**
- "Money is always stored in cents as integers. The `cents_to_dollars` macro handles the conversion at the presentation layer. This avoids floating-point precision issues that are catastrophic in financial reporting."

---

## Infrastructure and DR (5 minutes)

### Terraform Modules
7 modules covering the full GCP footprint: BigQuery, BigTable, Pub/Sub, GCS, IAM, Kubernetes, Cloud Composer, and Disaster Recovery.

### DR Strategy
- **BigQuery**: Daily dataset snapshots via Data Transfer Service. Restore is a metadata operation (instant).
- **GCS**: Cross-region replication via Storage Transfer (daily at 03:00 UTC). Backup bucket has 7-year lifecycle tiering.
- **Pub/Sub**: 7-day message retention allows replay from any point in the last week.
- **Monthly DR tests**: Cloud Scheduler triggers automated recovery validation on the first Monday of each month.

**Talking Point:**
- "RTO is <45 minutes because BigQuery snapshot restore is effectively instant -- it is a metadata pointer swap, not a data copy. The 45 minutes accounts for incident assessment (5 min), restore execution (15 min), GCS restore if needed (10 min), Pub/Sub replay (10 min), and validation (5 min)."

**Likely Follow-Up:**
- **Q: What about data corruption vs data loss?** A: Corruption is harder because you need to identify the last known good state. The 30-day snapshot retention gives us 30 restore points. For point-in-time recovery within a day, we replay from Pub/Sub (7-day retention) to reconstruct the exact sequence of events.

---

## Scaling Discussion (5 minutes)

| Scale | Events/day | Key Change |
|-------|-----------|------------|
| Current | 100K | System as built |
| 10x | 1M | Auto-scaling (BigTable nodes, GKE replicas, Airflow workers) |
| 100x | 10M | Add Dataflow streaming, partition Pub/Sub by event type |
| 1000x | 100M | Kafka replaces Pub/Sub, Spanner replaces BigTable, event sourcing |

**Talking Point:**
- "The architecture is designed so that 10x requires zero code changes -- only configuration adjustments. 100x requires adding one new component (Dataflow). 1000x is a meaningful architecture evolution, but the data model and dbt transformations remain unchanged."

---

## Security and Compliance (3 minutes)

**Key points to hit:**
1. **Data classification**: Three tiers (public aggregates, internal intermediates, confidential raw transactions)
2. **Workload Identity**: No JSON key files. GKE pods authenticate via Workload Identity Federation.
3. **Least privilege**: Every service account has minimum permissions. The IAM validation rejects primitive roles and public access.
4. **Audit trail**: 7-year retention, append-only BigQuery tables, every access check logged including denials.
5. **Network**: Private GKE nodes, VPC Service Controls, Cloud NAT for egress.

---

## Closing (2 minutes)

**Points to emphasize:**
- "The system is fully testable without GCP credentials. CI uses emulators (Pub/Sub, BigTable) and dry-run modes (dbt parse/compile, terraform validate)."
- "Every component has a clear responsibility boundary. The ingestion service does not know about dbt. The governance service does not know about Pub/Sub. This separation makes each component independently testable and replaceable."
- "The Makefile is the single interface for all operations: `make test`, `make lint`, `make up`, `make generate`. A new team member can run the full stack locally in under 5 minutes."

---

## Common Cross-Cutting Questions

**Q: What would you do differently?**
A: I would add Dataflow streaming from day one instead of batch Pub/Sub pull. The batch approach works for daily reporting, but the operational overhead of managing Pub/Sub subscriptions and ensuring exactly-once via MERGE is higher than a streaming pipeline that handles all of that automatically.

**Q: How do you handle schema changes across the pipeline?**
A: Schemas are defined in `schemas/` and are the single source of truth. The ingestion service embeds copies at build time. dbt models reference column names that must match. Schema changes require coordinated updates: schema definition, ingestion service, dbt staging model, and downstream tests. This is deliberate -- financial data schemas should change rarely and with full awareness of downstream impact.

**Q: Why GCP and not AWS?**
A: BigQuery is the strongest managed analytics offering for SQL-heavy workloads. GCP's serverless ecosystem (BigQuery, Pub/Sub, Cloud Composer) means less infrastructure management. The specific choice of GCP vs AWS matters less than the architectural patterns -- the three-path design (write/batch/read) and the separation of concerns would work identically on AWS with Kinesis/Glue/Athena/DynamoDB.

**Q: What is the hardest production incident you would anticipate?**
A: Silent data corruption in staging -- where values are wrong but not invalid. This is why the anomaly detection operator exists. Statistical deviation from the 30-day baseline catches scenarios like a billing system sending amounts in dollars instead of cents (100x spike) or a region code changing format. The custom dbt tests (`assert_revenue_non_negative`, `assert_date_completeness`) catch structural anomalies.
