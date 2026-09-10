output "cluster_name" {
  description = "The name of the GKE cluster, used by CI/CD pipelines to configure kubectl context."
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "The IP address of the GKE cluster's Kubernetes API server, used for kubectl and API client configuration."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "The base64-encoded public certificate of the cluster's CA, used to verify the API server's TLS certificate."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "namespace" {
  description = "Namespace the platform workloads run in."
  value       = kubernetes_namespace_v1.data_services.metadata[0].name
}

output "ingestion_service_dns" {
  description = "In-cluster DNS name of the ingestion service (port 80 -> container 8080)."
  value       = "${kubernetes_service_v1.ingestion.metadata[0].name}.${kubernetes_namespace_v1.data_services.metadata[0].name}.svc.cluster.local"
}

output "governance_service_dns" {
  description = "In-cluster DNS name of the governance service (port 80 -> container 8081)."
  value       = "${kubernetes_service_v1.governance.metadata[0].name}.${kubernetes_namespace_v1.data_services.metadata[0].name}.svc.cluster.local"
}

output "images" {
  description = "Container image references deployed for each service."
  value = {
    ingestion  = local.ingestion_image
    governance = local.governance_image
  }
}
