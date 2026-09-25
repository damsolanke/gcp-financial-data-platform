package publisher

import (
	"context"
	"encoding/json"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/pubsub/v2"
	"cloud.google.com/go/pubsub/v2/apiv1/pubsubpb"
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

// createTopic creates a topic through the v2 admin client and returns its full name.
func createTopic(ctx context.Context, t *testing.T, client *pubsub.Client, id string) string {
	t.Helper()
	name := "projects/" + testProjectID + "/topics/" + id
	if _, err := client.TopicAdminClient.CreateTopic(ctx, &pubsubpb.Topic{Name: name}); err != nil {
		t.Fatalf("creating topic %s: %v", id, err)
	}
	return name
}

// createSubscriber creates a subscription on topic and returns a subscriber for it.
func createSubscriber(ctx context.Context, t *testing.T, client *pubsub.Client, id, topic string) *pubsub.Subscriber {
	t.Helper()
	name := "projects/" + testProjectID + "/subscriptions/" + id
	if _, err := client.SubscriptionAdminClient.CreateSubscription(ctx, &pubsubpb.Subscription{
		Name:               name,
		Topic:              topic,
		AckDeadlineSeconds: 10,
	}); err != nil {
		t.Fatalf("creating subscription %s: %v", id, err)
	}
	return client.Subscriber(name)
}

// createTestTopicsAndSubs sets up topics and subscriptions for testing.
func createTestTopicsAndSubs(ctx context.Context, t *testing.T) (*pubsub.Client, *pubsub.Subscriber, *pubsub.Subscriber) {
	t.Helper()

	client, err := pubsub.NewClient(ctx, testProjectID)
	if err != nil {
		t.Fatalf("creating pubsub client: %v", err)
	}

	validatedTopic := createTopic(ctx, t, client, testTopicValidated)
	dlqTopic := createTopic(ctx, t, client, testTopicDLQ)
	validatedSub := createSubscriber(ctx, t, client, "validated-sub", validatedTopic)
	dlqSub := createSubscriber(ctx, t, client, "dlq-sub", dlqTopic)
	return client, validatedSub, dlqSub
}

func TestPubSubPublisher_Publish(t *testing.T) {
	skipIfNoEmulator(t)
	ctx := context.Background()

	client, validatedSub, _ := createTestTopicsAndSubs(ctx, t)
	defer func() { _ = client.Close() }()

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
	defer func() { _ = client.Close() }()

	dlqTopic := createTopic(ctx, t, client, dlqTopicName)

	// Also create the validated topic for the publisher constructor.
	validatedTopicName := "validated-events-test2"
	createTopic(ctx, t, client, validatedTopicName)

	dlqSub := createSubscriber(ctx, t, client, dlqSubName, dlqTopic)

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
	defer func() { _ = client.Close() }()

	validatedTopic := createTopic(ctx, t, client, stopValidatedTopic)
	createTopic(ctx, t, client, stopDLQTopic)
	sub := createSubscriber(ctx, t, client, stopSubName, validatedTopic)

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
