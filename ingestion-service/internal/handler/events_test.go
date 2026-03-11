package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	btwriter "github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/bigtable"
	"github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/metrics"
	"github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/publisher"
)

// --- Mock implementations ---

type mockPublisher struct {
	publishFunc    func(ctx context.Context, data []byte, attrs map[string]string) (string, error)
	publishDLQFunc func(ctx context.Context, data []byte, validationErrors []string) (string, error)
}

func (m *mockPublisher) Publish(ctx context.Context, data []byte, attrs map[string]string) (string, error) {
	if m.publishFunc != nil {
		return m.publishFunc(ctx, data, attrs)
	}
	return "msg-12345", nil
}

func (m *mockPublisher) PublishDLQ(ctx context.Context, data []byte, validationErrors []string) (string, error) {
	if m.publishDLQFunc != nil {
		return m.publishDLQFunc(ctx, data, validationErrors)
	}
	return "dlq-12345", nil
}

func (m *mockPublisher) Stop() {}

type mockWriter struct {
	writeFunc func(ctx context.Context, eventType, eventID string, timestamp time.Time, data []byte, metadata map[string]string) error
}

func (m *mockWriter) WriteEvent(ctx context.Context, eventType, eventID string, timestamp time.Time, data []byte, metadata map[string]string) error {
	if m.writeFunc != nil {
		return m.writeFunc(ctx, eventType, eventID, timestamp, data, metadata)
	}
	return nil
}

func (m *mockWriter) Close() error { return nil }

// Verify interface compliance at compile time.
var (
	_ publisher.EventPublisher = (*mockPublisher)(nil)
	_ btwriter.EventWriter     = (*mockWriter)(nil)
)

// --- Test helpers ---

func newTestHandler(pub *mockPublisher, w *mockWriter) *EventHandler {
	logger := zerolog.New(io.Discard)
	m := metrics.NewMetrics()
	if pub == nil {
		pub = &mockPublisher{}
	}
	if w == nil {
		w = &mockWriter{}
	}
	return NewEventHandler(pub, w, m, logger)
}

func validRevenueJSON() []byte {
	return []byte(`{
		"transaction_id": "550e8400-e29b-41d4-a716-446655440000",
		"timestamp": "2025-01-15T10:30:00Z",
		"amount_cents": 1500,
		"currency": "USD",
		"customer_id": "cust-12345",
		"product_line": "api_usage",
		"region": "us-east"
	}`)
}

func validUsageJSON() []byte {
	return []byte(`{
		"metric_id": "660e8400-e29b-41d4-a716-446655440001",
		"timestamp": "2025-01-15T10:30:00Z",
		"customer_id": "cust-12345",
		"metric_type": "api_calls",
		"quantity": 100,
		"unit": "calls"
	}`)
}

func validCostJSON() []byte {
	return []byte(`{
		"record_id": "770e8400-e29b-41d4-a716-446655440002",
		"timestamp": "2025-01-15T10:30:00Z",
		"cost_center": "engineering",
		"category": "compute",
		"amount_cents": 50000,
		"currency": "USD"
	}`)
}

func TestHandleIngestEvent(t *testing.T) {
	tests := []struct {
		name           string
		body           []byte
		queryType      string
		publisher      *mockPublisher
		writer         *mockWriter
		expectedStatus int
		checkBody      func(t *testing.T, body map[string]interface{})
	}{
		{
			name:           "valid revenue_transaction",
			body:           validRevenueJSON(),
			queryType:      "revenue_transaction",
			expectedStatus: http.StatusCreated,
			checkBody: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				if body["status"] != "accepted" {
					t.Errorf("expected status 'accepted', got %v", body["status"])
				}
				if body["event_id"] != "550e8400-e29b-41d4-a716-446655440000" {
					t.Errorf("unexpected event_id: %v", body["event_id"])
				}
				if body["publish_id"] == nil || body["publish_id"] == "" {
					t.Error("expected non-empty publish_id")
				}
			},
		},
		{
			name:           "valid usage_metric",
			body:           validUsageJSON(),
			queryType:      "usage_metric",
			expectedStatus: http.StatusCreated,
			checkBody: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				if body["status"] != "accepted" {
					t.Errorf("expected status 'accepted', got %v", body["status"])
				}
			},
		},
		{
			name:           "valid cost_record",
			body:           validCostJSON(),
			queryType:      "cost_record",
			expectedStatus: http.StatusCreated,
			checkBody: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				if body["status"] != "accepted" {
					t.Errorf("expected status 'accepted', got %v", body["status"])
				}
			},
		},
		{
			name:           "event_type from JSON field",
			body:           []byte(`{"event_type":"revenue_transaction","transaction_id":"550e8400-e29b-41d4-a716-446655440000","timestamp":"2025-01-15T10:30:00Z","amount_cents":1500,"currency":"USD","customer_id":"cust-12345","product_line":"api_usage","region":"us-east"}`),
			queryType:      "", // no query param; event_type from JSON
			expectedStatus: http.StatusCreated,
		},
		{
			name:           "invalid JSON",
			body:           []byte(`{not valid json`),
			queryType:      "revenue_transaction",
			expectedStatus: http.StatusBadRequest,
		},
		{
			name: "missing required field",
			body: []byte(`{
				"transaction_id": "550e8400-e29b-41d4-a716-446655440000",
				"timestamp": "2025-01-15T10:30:00Z",
				"currency": "USD",
				"customer_id": "cust-12345",
				"product_line": "api_usage",
				"region": "us-east"
			}`),
			queryType:      "revenue_transaction",
			expectedStatus: http.StatusBadRequest,
			checkBody: func(t *testing.T, body map[string]interface{}) {
				t.Helper()
				errors, ok := body["errors"]
				if !ok {
					t.Fatal("expected errors in response")
				}
				errList, ok := errors.([]interface{})
				if !ok || len(errList) == 0 {
					t.Fatal("expected non-empty errors array")
				}
			},
		},
		{
			name:           "unknown event_type",
			body:           []byte(`{"some_field": "value"}`),
			queryType:      "unknown_type",
			expectedStatus: http.StatusBadRequest,
		},
		{
			name:      "publisher failure returns 502",
			body:      validRevenueJSON(),
			queryType: "revenue_transaction",
			publisher: &mockPublisher{
				publishFunc: func(_ context.Context, _ []byte, _ map[string]string) (string, error) {
					return "", fmt.Errorf("pubsub unavailable")
				},
			},
			expectedStatus: http.StatusBadGateway,
		},
		{
			name:      "bigtable failure still returns 201",
			body:      validRevenueJSON(),
			queryType: "revenue_transaction",
			writer: &mockWriter{
				writeFunc: func(_ context.Context, _, _ string, _ time.Time, _ []byte, _ map[string]string) error {
					return fmt.Errorf("bigtable unavailable")
				},
			},
			expectedStatus: http.StatusCreated,
		},
		{
			name:           "empty body",
			body:           []byte{},
			queryType:      "revenue_transaction",
			expectedStatus: http.StatusBadRequest,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newTestHandler(tt.publisher, tt.writer)

			url := "/api/v1/events"
			if tt.queryType != "" {
				url += "?type=" + tt.queryType
			}

			req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(tt.body))
			req.Header.Set("Content-Type", "application/json")
			rec := httptest.NewRecorder()

			h.HandleIngestEvent(rec, req)

			if rec.Code != tt.expectedStatus {
				t.Errorf("status code: got %d, want %d\nbody: %s", rec.Code, tt.expectedStatus, rec.Body.String())
			}

			if tt.checkBody != nil {
				var respBody map[string]interface{}
				if err := json.Unmarshal(rec.Body.Bytes(), &respBody); err != nil {
					t.Fatalf("unmarshalling response: %v", err)
				}
				tt.checkBody(t, respBody)
			}
		})
	}
}

func TestHandleIngestEvent_BodyTooLarge(t *testing.T) {
	h := newTestHandler(nil, nil)

	// Create a body larger than 1MB.
	largeBody := bytes.Repeat([]byte("x"), maxBodySize+1)
	// Wrap it as valid-ish JSON so the size check triggers before parsing.
	payload := append([]byte(`{"data":"`), largeBody...)
	payload = append(payload, []byte(`"}`)...)

	req := httptest.NewRequest(http.MethodPost, "/api/v1/events?type=revenue_transaction", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	h.HandleIngestEvent(rec, req)

	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("expected 413, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestHandleHealthCheck(t *testing.T) {
	h := newTestHandler(nil, nil)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()

	h.HandleHealthCheck(rec, req)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}

	var resp map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshalling response: %v", err)
	}

	if resp["status"] != "healthy" {
		t.Errorf("expected status 'healthy', got %v", resp["status"])
	}

	checks, ok := resp["checks"].(map[string]interface{})
	if !ok {
		t.Fatal("expected checks object in response")
	}
	if checks["pubsub"] != "ok" {
		t.Errorf("expected pubsub check 'ok', got %v", checks["pubsub"])
	}
	if checks["bigtable"] != "ok" {
		t.Errorf("expected bigtable check 'ok', got %v", checks["bigtable"])
	}
}

func TestHandleIngestEvent_NoEventType(t *testing.T) {
	h := newTestHandler(nil, nil)

	body := []byte(`{"transaction_id": "abc-123"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/events", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	h.HandleIngestEvent(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "event_type") {
		t.Errorf("expected error about event_type, got: %s", rec.Body.String())
	}
}
