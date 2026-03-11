package publisher

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/pubsub"
)

const (
	testProjectID      = "test-project"
	testTopicValidated = "validated-events"
	testTopicDLQ       = "dlq-events"
)

func skipIfNoEmulator(t *testing.T) {
	t.Helper()
	if os.Getenv("PUBSUB_EMULATOR_HOST") == "" {
		t.Skip("PUBSUB_EMULATOR_HOST not set; skipping Pub/Sub emulator test")
	}
}

// createTestTopicsAndSubs sets up topics and subscriptions for testing.
func createTestTopicsAndSubs(ctx context.Context, t *testing.T) (*pubsub.Client, *pubsub.Subscription, *pubsub.Subscription) {
	t.Helper()

	client, err := pubsub.NewClient(ctx, testProjectID)
	if err != nil {
		t.Fatalf("creating pubsub client: %v", err)
	}

	validatedTopic, err := client.CreateTopic(ctx, testTopicValidated)
	if err != nil {
		t.Fatalf("creating validated topic: %v", err)
	}

	dlqTopic, err := client.CreateTopic(ctx, testTopicDLQ)
	if err != nil {
		t.Fatalf("creating DLQ topic: %v", err)
	}

	validatedSub, err := client.CreateSubscription(ctx, "validated-sub", pubsub.SubscriptionConfig{
		Topic:       validatedTopic,
		AckDeadline: 10 * time.Second,
	})
	if err != nil {
		t.Fatalf("creating validated subscription: %v", err)
	}

	dlqSub, err := client.CreateSubscription(ctx, "dlq-sub", pubsub.SubscriptionConfig{
		Topic:       dlqTopic,
		AckDeadline: 10 * time.Second,
	})
	if err != nil {
		t.Fatalf("creating DLQ subscription: %v", err)
	}

	return client, validatedSub, dlqSub
}

func TestPubSubPublisher_Publish(t *testing.T) {
	skipIfNoEmulator(t)
	ctx := context.Background()

	client, validatedSub, _ := createTestTopicsAndSubs(ctx, t)
	defer client.Close()

	publisher, err := NewPubSubPublisher(ctx, testProjectID, testTopicValidated, testTopicDLQ)
	if err != nil {
		t.Fatalf("creating publisher: %v", err)
	}
	defer publisher.Stop()

	testData := []byte(`{"transaction_id":"abc-123"}`)
	attrs := map[string]string{
		"event_type": "revenue_transaction",
		"event_id":   "abc-123",
	}

	msgID, err := publisher.Publish(ctx, testData, attrs)
	if err != nil {
		t.Fatalf("publishing message: %v", err)
	}
	if msgID == "" {
		t.Fatal("expected non-empty message ID")
	}

	// Receive and verify the message.
	receiveCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var received *pubsub.Message
	err = validatedSub.Receive(receiveCtx, func(_ context.Context, msg *pubsub.Message) {
		received = msg
		msg.Ack()
		cancel()
	})
	if err != nil && receiveCtx.Err() == nil {
		t.Fatalf("receiving message: %v", err)
	}

	if received == nil {
		t.Fatal("did not receive published message")
	}
	if string(received.Data) != string(testData) {
		t.Errorf("data mismatch: got %q, want %q", received.Data, testData)
	}
	if received.Attributes["event_type"] != "revenue_transaction" {
		t.Errorf("attribute event_type: got %q, want %q", received.Attributes["event_type"], "revenue_transaction")
	}
}

func TestPubSubPublisher_PublishDLQ(t *testing.T) {
	skipIfNoEmulator(t)
	ctx := context.Background()

	// Use unique topic names to avoid conflicts with other tests.
	dlqTopicName := "dlq-events-test2"
	dlqSubName := "dlq-sub-test2"

	client, err := pubsub.NewClient(ctx, testProjectID)
	if err != nil {
		t.Fatalf("creating pubsub client: %v", err)
	}
	defer client.Close()

	dlqTopic, err := client.CreateTopic(ctx, dlqTopicName)
	if err != nil {
		t.Fatalf("creating DLQ topic: %v", err)
	}

	// Also create the validated topic for the publisher constructor.
	validatedTopicName := "validated-events-test2"
	_, err = client.CreateTopic(ctx, validatedTopicName)
	if err != nil {
		t.Fatalf("creating validated topic: %v", err)
	}

	dlqSub, err := client.CreateSubscription(ctx, dlqSubName, pubsub.SubscriptionConfig{
		Topic:       dlqTopic,
		AckDeadline: 10 * time.Second,
	})
	if err != nil {
		t.Fatalf("creating DLQ subscription: %v", err)
	}

	publisher, err := NewPubSubPublisher(ctx, testProjectID, validatedTopicName, dlqTopicName)
	if err != nil {
		t.Fatalf("creating publisher: %v", err)
	}
	defer publisher.Stop()

	testData := []byte(`{"bad":"data"}`)
	validationErrors := []string{"missing field: transaction_id", "invalid type for amount_cents"}

	msgID, err := publisher.PublishDLQ(ctx, testData, validationErrors)
	if err != nil {
		t.Fatalf("publishing to DLQ: %v", err)
	}
	if msgID == "" {
		t.Fatal("expected non-empty message ID")
	}

	receiveCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var received *pubsub.Message
	err = dlqSub.Receive(receiveCtx, func(_ context.Context, msg *pubsub.Message) {
		received = msg
		msg.Ack()
		cancel()
	})
	if err != nil && receiveCtx.Err() == nil {
		t.Fatalf("receiving DLQ message: %v", err)
	}

	if received == nil {
		t.Fatal("did not receive DLQ message")
	}
	if received.Attributes["error_count"] != "2" {
		t.Errorf("error_count: got %q, want %q", received.Attributes["error_count"], "2")
	}
	if received.Attributes["received_at"] == "" {
		t.Error("expected received_at attribute to be set")
	}

	var errList []string
	if err := json.Unmarshal([]byte(received.Attributes["errors"]), &errList); err != nil {
		t.Fatalf("unmarshalling errors attribute: %v", err)
	}
	if len(errList) != 2 {
		t.Errorf("expected 2 errors, got %d", len(errList))
	}
}

func TestPubSubPublisher_StopFlushes(t *testing.T) {
	skipIfNoEmulator(t)
	ctx := context.Background()

	stopValidatedTopic := "validated-events-stop"
	stopDLQTopic := "dlq-events-stop"
	stopSubName := "validated-sub-stop"

	client, err := pubsub.NewClient(ctx, testProjectID)
	if err != nil {
		t.Fatalf("creating pubsub client: %v", err)
	}
	defer client.Close()

	validatedTopic, err := client.CreateTopic(ctx, stopValidatedTopic)
	if err != nil {
		t.Fatalf("creating topic: %v", err)
	}
	_, err = client.CreateTopic(ctx, stopDLQTopic)
	if err != nil {
		t.Fatalf("creating DLQ topic: %v", err)
	}

	sub, err := client.CreateSubscription(ctx, stopSubName, pubsub.SubscriptionConfig{
		Topic:       validatedTopic,
		AckDeadline: 10 * time.Second,
	})
	if err != nil {
		t.Fatalf("creating subscription: %v", err)
	}

	publisher, err := NewPubSubPublisher(ctx, testProjectID, stopValidatedTopic, stopDLQTopic)
	if err != nil {
		t.Fatalf("creating publisher: %v", err)
	}

	// Publish several messages and stop without waiting for individual results.
	for i := 0; i < 5; i++ {
		_, err := publisher.Publish(ctx, []byte(`{"id":"flush-test"}`), map[string]string{"i": "test"})
		if err != nil {
			t.Fatalf("publishing: %v", err)
		}
	}

	publisher.Stop()

	// Verify all messages were flushed by receiving them.
	receiveCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	count := 0
	err = sub.Receive(receiveCtx, func(_ context.Context, msg *pubsub.Message) {
		msg.Ack()
		count++
		if count >= 5 {
			cancel()
		}
	})
	if err != nil && receiveCtx.Err() == nil {
		t.Fatalf("receiving messages: %v", err)
	}

	if count < 5 {
		t.Errorf("expected 5 flushed messages, got %d", count)
	}
}
