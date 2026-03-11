// Package publisher provides event publishing to Google Cloud Pub/Sub topics.
package publisher

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"cloud.google.com/go/pubsub"
)

// EventPublisher defines the interface for publishing validated and failed events.
type EventPublisher interface {
	Publish(ctx context.Context, data []byte, attrs map[string]string) (string, error)
	PublishDLQ(ctx context.Context, data []byte, validationErrors []string) (string, error)
	Stop()
}

// PubSubPublisher implements EventPublisher using Google Cloud Pub/Sub.
type PubSubPublisher struct {
	client         *pubsub.Client
	topicValidated *pubsub.Topic
	topicDLQ       *pubsub.Topic
}

// NewPubSubPublisher creates a new PubSubPublisher connected to the given project
// and configured with the specified topics. It configures batching for throughput.
func NewPubSubPublisher(ctx context.Context, projectID, topicValidated, topicDLQ string) (*PubSubPublisher, error) {
	client, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		return nil, fmt.Errorf("creating pubsub client: %w", err)
	}

	validated := client.Topic(topicValidated)
	validated.PublishSettings = pubsub.PublishSettings{
		ByteThreshold:  1_000_000, // 1 MB
		CountThreshold: 100,
		DelayThreshold: 100 * time.Millisecond,
	}

	dlq := client.Topic(topicDLQ)
	dlq.PublishSettings = pubsub.PublishSettings{
		ByteThreshold:  1_000_000,
		CountThreshold: 100,
		DelayThreshold: 100 * time.Millisecond,
	}

	return &PubSubPublisher{
		client:         client,
		topicValidated: validated,
		topicDLQ:       dlq,
	}, nil
}

// Publish sends validated event data to the validated topic with the given attributes.
// It returns the server-assigned message ID.
func (p *PubSubPublisher) Publish(ctx context.Context, data []byte, attrs map[string]string) (string, error) {
	result := p.topicValidated.Publish(ctx, &pubsub.Message{
		Data:       data,
		Attributes: attrs,
	})

	serverID, err := result.Get(ctx)
	if err != nil {
		return "", fmt.Errorf("publishing to validated topic: %w", err)
	}

	return serverID, nil
}

// PublishDLQ sends failed event data to the dead-letter queue topic. Validation
// errors are attached as message attributes for downstream inspection.
func (p *PubSubPublisher) PublishDLQ(ctx context.Context, data []byte, validationErrors []string) (string, error) {
	errorsJSON, err := json.Marshal(validationErrors)
	if err != nil {
		return "", fmt.Errorf("marshalling validation errors: %w", err)
	}

	attrs := map[string]string{
		"error_count": strconv.Itoa(len(validationErrors)),
		"errors":      string(errorsJSON),
		"received_at": time.Now().UTC().Format(time.RFC3339Nano),
	}

	result := p.topicDLQ.Publish(ctx, &pubsub.Message{
		Data:       data,
		Attributes: attrs,
	})

	serverID, err := result.Get(ctx)
	if err != nil {
		return "", fmt.Errorf("publishing to DLQ topic: %w", err)
	}

	return serverID, nil
}

// Stop flushes any pending messages and releases resources for both topics.
func (p *PubSubPublisher) Stop() {
	p.topicValidated.Stop()
	p.topicDLQ.Stop()
}
