output "validated_topic_id" {
  description = "Full resource ID of the validated events topic, used for IAM bindings and subscription configuration."
  value       = google_pubsub_topic.validated.id
}

output "validated_topic_name" {
  description = "Short name of the validated events topic, used by publisher applications to target message delivery."
  value       = google_pubsub_topic.validated.name
}

output "dlq_topic_id" {
  description = "Full resource ID of the dead-letter topic, used for monitoring and alerting configuration."
  value       = google_pubsub_topic.dead_letter.id
}

output "dlq_topic_name" {
  description = "Short name of the dead-letter topic, used by operators for manual message inspection."
  value       = google_pubsub_topic.dead_letter.name
}

output "validated_subscription_id" {
  description = "Full resource ID of the validated events subscription, used for consumer service configuration."
  value       = google_pubsub_subscription.validated.id
}

output "dlq_subscription_id" {
  description = "Full resource ID of the DLQ subscription, used for alerting and manual replay tooling."
  value       = google_pubsub_subscription.dead_letter.id
}
