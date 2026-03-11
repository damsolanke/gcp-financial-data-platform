# -----------------------------------------------------------------------------
# Kubernetes (GKE) Module
# -----------------------------------------------------------------------------
# This module provisions a GKE Autopilot cluster and deploys the data platform
# microservices. Autopilot is chosen over Standard mode because:
#   1. Node management is fully automated (no node pool sizing decisions)
#   2. Per-pod billing aligns with our microservices architecture
#   3. Built-in security hardening (shielded nodes, workload identity)
#   4. Automatic bin-packing reduces wasted compute
#
# Two services run on this cluster:
#   - ingestion-service: receives raw financial events, validates them,
#     publishes to Pub/Sub, and writes to Bigtable
#   - governance-service: monitors access patterns, enforces data policies,
#     and writes to the audit dataset
# -----------------------------------------------------------------------------

locals {
  cluster_name = "fdp-${var.environment}-cluster"

  common_labels = merge(var.labels, {
    environment = var.environment
    managed_by  = "terraform"
    module      = "kubernetes"
  })
}

# ---------------------------------------------------------------------------
# GKE Autopilot Cluster
# ---------------------------------------------------------------------------

resource "google_container_cluster" "primary" {
  project  = var.project_id
  name     = local.cluster_name
  location = var.region

  # Autopilot manages node pools automatically. This eliminates the need to
  # configure node pools, machine types, and autoscaling — GKE handles it
  # based on pod resource requests.
  enable_autopilot = true

  # REGULAR channel balances stability with feature freshness. RAPID gets
  # features sooner but may have more churn; STABLE lags significantly.
  release_channel {
    channel = "REGULAR"
  }

  network    = var.network_id
  subnetwork = var.subnet_id

  # Workload Identity is the recommended way to authenticate pods to GCP
  # services. It eliminates the need for JSON key files and provides
  # automatic credential rotation.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Private cluster configuration keeps nodes off the public internet.
  # The control plane is still accessible via its external endpoint for
  # CI/CD pipelines, but nodes can only be reached via internal IPs.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # Allow kubectl access from CI/CD

    # /28 is the minimum CIDR for the control plane. This range must not
    # overlap with any subnet in the VPC.
    master_ipv4_cidr_block = "172.16.0.0/28"
  }

  # Prevent accidental deletion in production.
  deletion_protection = var.environment == "prod" ? true : false

  resource_labels = local.common_labels
}

# ---------------------------------------------------------------------------
# Kubernetes Provider Configuration
# ---------------------------------------------------------------------------
# The Kubernetes provider is configured using the cluster's endpoint and CA
# certificate. This allows Terraform to manage Kubernetes resources directly.

data "google_client_config" "default" {}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
# All data platform services run in a dedicated namespace to isolate them
# from other workloads and simplify RBAC and network policy management.

resource "kubernetes_namespace_v1" "data_services" {
  metadata {
    name = "data-services"
    labels = {
      environment = var.environment
      managed_by  = "terraform"
    }
  }

  depends_on = [google_container_cluster.primary]
}

# ---------------------------------------------------------------------------
# Ingestion Service Deployment
# ---------------------------------------------------------------------------
# The ingestion service is the entry point for all financial data. It receives
# events via HTTP/gRPC, validates them against the schema, and publishes
# validated events to Pub/Sub while writing to Bigtable for deduplication.

resource "kubernetes_deployment_v1" "ingestion_service" {
  metadata {
    name      = "ingestion-service"
    namespace = kubernetes_namespace_v1.data_services.metadata[0].name
    labels = {
      app         = "ingestion-service"
      environment = var.environment
    }
  }

  spec {
    # Two replicas ensure availability during rolling updates and single-pod
    # failures. The HPA scales beyond this based on CPU utilization.
    replicas = 2

    selector {
      match_labels = {
        app = "ingestion-service"
      }
    }

    template {
      metadata {
        labels = {
          app         = "ingestion-service"
          environment = var.environment
        }
        annotations = {
          # Workload Identity annotation tells GKE to provide the pod with
          # credentials for the specified GCP service account.
          "iam.gke.io/gcp-service-account" = var.ingestion_sa_email
        }
      }

      spec {
        # The Kubernetes service account name must match the Workload Identity
        # binding created in the IAM module.
        service_account_name = "ingestion-service"

        container {
          name  = "ingestion-service"
          image = "gcr.io/${var.project_id}/ingestion-service:latest"

          # Resource requests are set to match typical steady-state usage.
          # Limits are 2x requests to handle brief spikes without OOMKill.
          resources {
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "GCP_PROJECT_ID"
            value = var.project_id
          }

          env {
            name  = "ENVIRONMENT"
            value = var.environment
          }

          # Liveness probe detects deadlocked processes. If the service stops
          # responding for 30 seconds (3 * 10s), Kubernetes restarts the pod.
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          # Readiness probe controls whether the pod receives traffic. A pod
          # that fails readiness is removed from the Service endpoint until
          # it recovers. This prevents sending traffic to pods that are still
          # warming up or experiencing transient issues.
          readiness_probe {
            http_get {
              path = "/readyz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.data_services]
}

# ---------------------------------------------------------------------------
# Governance Service Deployment
# ---------------------------------------------------------------------------
# The governance service monitors data access patterns, enforces retention
# policies, and writes audit events. It runs alongside the ingestion service
# but has different network access requirements (BigQuery only).

resource "kubernetes_deployment_v1" "governance_service" {
  metadata {
    name      = "governance-service"
    namespace = kubernetes_namespace_v1.data_services.metadata[0].name
    labels = {
      app         = "governance-service"
      environment = var.environment
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "governance-service"
      }
    }

    template {
      metadata {
        labels = {
          app         = "governance-service"
          environment = var.environment
        }
        annotations = {
          "iam.gke.io/gcp-service-account" = var.governance_sa_email
        }
      }

      spec {
        service_account_name = "governance-service"

        container {
          name  = "governance-service"
          image = "gcr.io/${var.project_id}/governance-service:latest"

          resources {
            requests = {
              cpu    = "250m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          port {
            container_port = 8080
            name           = "http"
          }

          env {
            name  = "GCP_PROJECT_ID"
            value = var.project_id
          }

          env {
            name  = "ENVIRONMENT"
            value = var.environment
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/readyz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.data_services]
}

# ---------------------------------------------------------------------------
# Horizontal Pod Autoscaler
# ---------------------------------------------------------------------------
# The ingestion service is the most likely to experience traffic spikes
# (e.g., batch uploads, end-of-month reconciliation). The HPA scales
# from 2 to 10 replicas based on CPU utilization.

resource "kubernetes_horizontal_pod_autoscaler_v2" "ingestion_hpa" {
  metadata {
    name      = "ingestion-service-hpa"
    namespace = kubernetes_namespace_v1.data_services.metadata[0].name
  }

  spec {
    min_replicas = 2
    max_replicas = 10

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.ingestion_service.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }

    # Scale-down stabilization window prevents flapping: the HPA waits 5
    # minutes after the last scale-up before considering scale-down.
    behavior {
      scale_down {
        stabilization_window_seconds = 300
        select_policy                = "Min"
        policy {
          type           = "Percent"
          value          = 10
          period_seconds = 60
        }
      }
      scale_up {
        stabilization_window_seconds = 30
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 60
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Network Policies
# ---------------------------------------------------------------------------
# Network policies implement micro-segmentation: each service can only reach
# the specific GCP APIs it needs. This limits lateral movement if a pod is
# compromised.

# Ingestion service: allowed to egress to Pub/Sub (port 443) and Bigtable
# (port 443). All other egress is denied.
resource "kubernetes_network_policy_v1" "ingestion_egress" {
  metadata {
    name      = "ingestion-egress"
    namespace = kubernetes_namespace_v1.data_services.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "ingestion-service"
      }
    }

    # Allow DNS resolution (required for all GCP API calls)
    egress {
      ports {
        port     = 53
        protocol = "UDP"
      }
      ports {
        port     = 53
        protocol = "TCP"
      }
    }

    # Allow HTTPS egress to GCP APIs (Pub/Sub and Bigtable both use port 443).
    # In a production setup, you would further restrict this with IP-based
    # rules targeting GCP's published API IP ranges.
    egress {
      ports {
        port     = 443
        protocol = "TCP"
      }
    }

    # Bigtable also uses port 8443 for some data operations.
    egress {
      ports {
        port     = 8443
        protocol = "TCP"
      }
    }

    policy_types = ["Egress"]
  }
}

# Governance service: allowed to egress to BigQuery (port 443) only.
resource "kubernetes_network_policy_v1" "governance_egress" {
  metadata {
    name      = "governance-egress"
    namespace = kubernetes_namespace_v1.data_services.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "governance-service"
      }
    }

    # Allow DNS resolution
    egress {
      ports {
        port     = 53
        protocol = "UDP"
      }
      ports {
        port     = 53
        protocol = "TCP"
      }
    }

    # Allow HTTPS egress to GCP APIs (BigQuery uses port 443).
    egress {
      ports {
        port     = 443
        protocol = "TCP"
      }
    }

    policy_types = ["Egress"]
  }
}

# ---------------------------------------------------------------------------
# Pod Disruption Budgets
# ---------------------------------------------------------------------------
# PDBs ensure at least one pod of each service remains available during
# voluntary disruptions (node upgrades, cluster autoscaler scale-down).
# This is critical for the ingestion service to avoid dropping events
# during maintenance windows.

resource "kubernetes_pod_disruption_budget_v1" "ingestion_pdb" {
  metadata {
    name      = "ingestion-service-pdb"
    namespace = kubernetes_namespace_v1.data_services.metadata[0].name
  }

  spec {
    min_available = 1

    selector {
      match_labels = {
        app = "ingestion-service"
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "governance_pdb" {
  metadata {
    name      = "governance-service-pdb"
    namespace = kubernetes_namespace_v1.data_services.metadata[0].name
  }

  spec {
    min_available = 1

    selector {
      match_labels = {
        app = "governance-service"
      }
    }
  }
}
