#!/usr/bin/env python3
"""Generate architecture diagrams for the GCP Financial Data Platform."""

import os

from diagrams import Cluster, Diagram, Edge
from diagrams.gcp.analytics import BigQuery, PubSub
from diagrams.gcp.compute import GKE
from diagrams.gcp.database import Bigtable
from diagrams.gcp.operations import Monitoring
from diagrams.gcp.security import Iam
from diagrams.gcp.storage import GCS
from diagrams.onprem.workflow import Airflow
from diagrams.programming.framework import FastAPI

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "docs", "images")

CLUSTER_FONT = "Helvetica Neue Bold"
FONT = "Helvetica Neue"


def architecture_diagram():
    """Main system architecture — full platform view with GCP icons."""
    with Diagram(
        "",
        filename=os.path.join(OUTPUT_DIR, "architecture"),
        outformat="png",
        show=False,
        direction="LR",
        graph_attr={
            "fontsize": "11",
            "fontname": FONT,
            "bgcolor": "#ffffff",
            "pad": "0.6",
            "nodesep": "0.5",
            "ranksep": "0.8",
            "dpi": "150",
        },
        node_attr={"fontsize": "10", "fontname": FONT},
        edge_attr={"fontsize": "8", "fontname": FONT, "color": "#666666"},
    ):
        # --- Schema contract ---
        with Cluster(
            "Schema Contract  ·  schemas/*.json",
            graph_attr={
                "bgcolor": "#FFF8E1",
                "style": "rounded",
                "fontsize": "11",
                "fontname": CLUSTER_FONT,
                "pencolor": "#F9A825",
                "penwidth": "2.0",
            },
        ):
            schema = BigQuery("revenue_transaction\nusage_metric\ncost_record")

        # --- Write path ---
        with Cluster(
            "Write Path  ·  Go  ·  P99 <100ms",
            graph_attr={
                "bgcolor": "#E8F5E9",
                "style": "rounded",
                "fontsize": "11",
                "fontname": CLUSTER_FONT,
                "pencolor": "#2E7D32",
                "penwidth": "2.0",
            },
        ):
            ingestion = GKE("Ingestion Service\nvalidate · publish · write")

        # --- Streaming backbone ---
        with Cluster(
            "Event Backbone  ·  Pub/Sub",
            graph_attr={
                "bgcolor": "#E3F2FD",
                "style": "rounded",
                "fontsize": "11",
                "fontname": CLUSTER_FONT,
                "pencolor": "#1565C0",
                "penwidth": "2.0",
            },
        ):
            pubsub = PubSub("Validated Events\nexactly-once · 7d retention")
            dlq = PubSub("Dead Letter Queue\n30d retention")

        # --- Hot path ---
        with Cluster(
            "Hot Path  ·  BigTable",
            graph_attr={
                "bgcolor": "#FCE4EC",
                "style": "rounded",
                "fontsize": "11",
                "fontname": CLUSTER_FONT,
                "pencolor": "#C62828",
                "penwidth": "2.0",
            },
        ):
            bigtable = Bigtable("Financial Events\nreverse-ts keys · 90d TTL")

        # --- Batch path ---
        with Cluster(
            "Batch Path  ·  Airflow + dbt  ·  daily 02:00 UTC",
            graph_attr={
                "bgcolor": "#E8EAF6",
                "style": "rounded",
                "fontsize": "11",
                "fontname": CLUSTER_FONT,
                "pencolor": "#283593",
                "penwidth": "2.0",
            },
        ):
            composer = Airflow("Cloud Composer\nMERGE dedup · SLA 4h")
            with Cluster(
                "dbt  ·  staging → intermediate → marts",
                graph_attr={
                    "bgcolor": "#C5CAE9",
                    "style": "rounded",
                    "fontsize": "10",
                    "fontname": CLUSTER_FONT,
                    "pencolor": "#3949AB",
                    "penwidth": "1.5",
                },
            ):
                staging = BigQuery("Staging\nviews · dedup")
                marts = BigQuery("Marts\npartitioned · clustered")
            anomaly = Monitoring("Anomaly Detection\n2σ rolling 30d")

        # --- Read path ---
        with Cluster(
            "Read Path  ·  FastAPI  ·  P99 <50ms",
            graph_attr={
                "bgcolor": "#FFF3E0",
                "style": "rounded",
                "fontsize": "11",
                "fontname": CLUSTER_FONT,
                "pencolor": "#E65100",
                "penwidth": "2.0",
            },
        ):
            governance = FastAPI("Governance Service\nRBAC · Audit · IAM Sync")
            rbac = Iam("5 roles · glob patterns\n7yr audit · SOX")

        # --- Storage + DR ---
        with Cluster(
            "Storage + Disaster Recovery",
            graph_attr={
                "bgcolor": "#F3E5F5",
                "style": "rounded",
                "fontsize": "11",
                "fontname": CLUSTER_FONT,
                "pencolor": "#6A1B9A",
                "penwidth": "2.0",
            },
        ):
            gcs_raw = GCS("Raw · US multi-region")
            gcs_backup = GCS("Backup · cross-region\nlifecycle tiering → 7yr")
            bq_snap = BigQuery("BQ Snapshots\ndaily · 30d")

        # --- Edges: schema contract ---
        schema >> Edge(label="go:embed", style="dashed", color="#F9A825", penwidth="1.5") >> ingestion

        # --- Edges: write path ---
        ingestion >> Edge(label="valid", color="#2E7D32", penwidth="2.0") >> pubsub
        ingestion >> Edge(label="invalid", color="#C62828", style="dashed") >> dlq
        ingestion >> Edge(label="best-effort", color="#C62828", style="dashed") >> bigtable
        ingestion >> Edge(color="#6A1B9A", style="dashed") >> gcs_raw

        # --- Edges: batch path ---
        pubsub >> Edge(label="daily pull", color="#1565C0", penwidth="2.0") >> composer
        composer >> Edge(color="#283593", penwidth="1.5") >> staging
        staging >> Edge(label="dbt run", color="#283593", penwidth="2.0") >> marts
        composer >> Edge(style="dashed", color="#283593") >> anomaly

        # --- Edges: read path ---
        marts >> Edge(color="#E65100", penwidth="2.0") >> governance
        governance >> Edge(color="#E65100") >> rbac

        # --- Edges: DR ---
        gcs_raw >> Edge(label="Storage Transfer\n03:00 UTC", color="#6A1B9A", style="dashed") >> gcs_backup
        marts >> Edge(style="dashed", color="#6A1B9A") >> bq_snap


def event_lifecycle_diagram():
    """Single event journey from API call to governed report access."""
    with Diagram(
        "",
        filename=os.path.join(OUTPUT_DIR, "event-lifecycle"),
        outformat="png",
        show=False,
        direction="LR",
        graph_attr={
            "fontsize": "11",
            "fontname": FONT,
            "bgcolor": "#ffffff",
            "pad": "0.6",
            "nodesep": "0.7",
            "ranksep": "0.9",
            "dpi": "150",
        },
        node_attr={"fontsize": "10", "fontname": FONT},
        edge_attr={"fontsize": "8", "fontname": FONT, "color": "#666666"},
    ):
        # Write path cluster keeps ingestion + fan-out together
        with Cluster(
            "Write Path",
            graph_attr={
                "bgcolor": "#E8F5E9",
                "style": "rounded",
                "fontsize": "10",
                "fontname": CLUSTER_FONT,
                "pencolor": "#2E7D32",
                "penwidth": "2.0",
            },
        ):
            ingestion = GKE("Go Service\nvalidate · route")
            pubsub = PubSub("Pub/Sub\nexactly-once")
            bigtable = Bigtable("BigTable\nhot path")
            dlq = PubSub("DLQ")

        # Batch
        composer = Airflow("Airflow\nMERGE dedup")

        # dbt layers
        with Cluster(
            "dbt Transforms",
            graph_attr={
                "bgcolor": "#E8EAF6",
                "style": "rounded",
                "fontsize": "10",
                "fontname": CLUSTER_FONT,
                "pencolor": "#283593",
                "penwidth": "2.0",
            },
        ):
            stg = BigQuery("Staging\ndedup + cast")
            inter = BigQuery("Intermediate\nbusiness logic")
            mart = BigQuery("Marts\npartitioned")

        # Governance
        gov = FastAPI("Governance\nRBAC · Audit")

        # --- Happy path (bold) ---
        ingestion >> Edge(label="valid", color="#2E7D32", penwidth="2.5") >> pubsub
        pubsub >> Edge(label="daily batch", color="#1565C0", penwidth="2.5") >> composer
        composer >> Edge(color="#283593", penwidth="2.0") >> stg
        stg >> Edge(color="#283593", penwidth="2.0") >> inter
        inter >> Edge(color="#283593", penwidth="2.0") >> mart
        mart >> Edge(label="governed\naccess", color="#E65100", penwidth="2.5") >> gov

        # --- Secondary paths (dashed) ---
        ingestion >> Edge(label="best-effort", color="#C62828", style="dashed") >> bigtable
        ingestion >> Edge(label="invalid", color="#999999", style="dashed") >> dlq


if __name__ == "__main__":
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    print("Generating architecture diagram...")
    architecture_diagram()
    print("Generating event lifecycle diagram...")
    event_lifecycle_diagram()
    print(f"Done. Images in {OUTPUT_DIR}/")
