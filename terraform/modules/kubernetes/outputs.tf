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
