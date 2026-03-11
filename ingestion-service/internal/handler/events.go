// Package handler implements HTTP handlers for the ingestion service API.
package handler

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/rs/zerolog"

	btwriter "github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/bigtable"
	"github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/metrics"
	"github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/publisher"
	"github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/validator"
)

const maxBodySize = 1 << 20 // 1 MB

// eventIDFields maps event types to their respective ID field names.
var eventIDFields = map[string]string{
	"revenue_transaction": "transaction_id",
	"usage_metric":        "metric_id",
	"cost_record":         "record_id",
}

// EventHandler handles HTTP requests for event ingestion.
type EventHandler struct {
	publisher publisher.EventPublisher
	writer    btwriter.EventWriter
	metrics   *metrics.Metrics
	logger    zerolog.Logger
}

// NewEventHandler creates a new EventHandler with the given dependencies.
func NewEventHandler(pub publisher.EventPublisher, w btwriter.EventWriter, m *metrics.Metrics, logger zerolog.Logger) *EventHandler {
	return &EventHandler{
		publisher: pub,
		writer:    w,
		metrics:   m,
		logger:    logger,
	}
}

// HandleIngestEvent processes incoming event payloads: validates, publishes
// to Pub/Sub, and writes to Bigtable.
func (h *EventHandler) HandleIngestEvent(w http.ResponseWriter, r *http.Request) {
	// Limit request body size.
	r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)

	body, err := io.ReadAll(r.Body)
	if err != nil {
		// MaxBytesReader returns *http.MaxBytesError (Go 1.19+).
		if _, ok := err.(*http.MaxBytesError); ok {
			respondError(w, http.StatusRequestEntityTooLarge, "request body exceeds 1MB limit")
			return
		}
		h.logger.Error().Err(err).Msg("reading request body")
		respondError(w, http.StatusBadRequest, "failed to read request body")
		return
	}

	if len(body) == 0 {
		respondError(w, http.StatusBadRequest, "request body is empty")
		return
	}

	// Parse the JSON to extract event_type and event_id.
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(body, &payload); err != nil {
		respondError(w, http.StatusBadRequest, fmt.Sprintf("invalid JSON: %s", err.Error()))
		return
	}

	// Determine event type from JSON field or query parameter.
	eventType := r.URL.Query().Get("type")
	if raw, ok := payload["event_type"]; ok && eventType == "" {
		var et string
		if err := json.Unmarshal(raw, &et); err == nil {
			eventType = et
		}
	}

	if eventType == "" {
		respondError(w, http.StatusBadRequest, "event_type is required (JSON field or ?type= query param)")
		return
	}

	h.metrics.EventsReceived.WithLabelValues(eventType).Inc()

	// Determine the event ID field name for this event type.
	idField, ok := eventIDFields[eventType]
	if !ok {
		respondError(w, http.StatusBadRequest, fmt.Sprintf("unknown event_type: %q", eventType))
		return
	}

	// Extract event ID from payload.
	var eventID string
	if raw, exists := payload[idField]; exists {
		if err := json.Unmarshal(raw, &eventID); err != nil {
			respondError(w, http.StatusBadRequest, fmt.Sprintf("invalid %s field: %s", idField, err.Error()))
			return
		}
	}

	// Validate the event against its schema.
	// Strip event_type from the body before validation if present,
	// since the schemas use additionalProperties: false.
	validationBody := body
	if _, hasEventType := payload["event_type"]; hasEventType {
		stripped := make(map[string]json.RawMessage, len(payload)-1)
		for k, v := range payload {
			if k != "event_type" {
				stripped[k] = v
			}
		}
		validationBody, err = json.Marshal(stripped)
		if err != nil {
			h.logger.Error().Err(err).Msg("re-marshalling payload for validation")
			respondError(w, http.StatusInternalServerError, "internal error")
			return
		}
	}

	validationStart := time.Now()
	validationErrs, err := validator.ValidateEvent(eventType, validationBody)
	h.metrics.ValidationLatency.WithLabelValues(eventType).Observe(time.Since(validationStart).Seconds())

	if err != nil {
		h.logger.Error().Err(err).Str("event_type", eventType).Msg("validation error")
		respondError(w, http.StatusBadRequest, err.Error())
		return
	}

	if len(validationErrs) > 0 {
		h.metrics.EventsValidated.WithLabelValues(eventType, "failed").Inc()
		h.metrics.EventsFailed.WithLabelValues(eventType, "validation").Inc()

		errorMessages := make([]string, len(validationErrs))
		errorDetails := make([]map[string]string, len(validationErrs))
		for i, ve := range validationErrs {
			errorMessages[i] = fmt.Sprintf("%s: %s", ve.Field, ve.Message)
			errorDetails[i] = map[string]string{
				"field":   ve.Field,
				"message": ve.Message,
				"type":    ve.Type,
			}
		}

		// Publish to DLQ asynchronously. Use a detached context since the
		// request context will be cancelled once the HTTP response is sent.
		go func() {
			dlqCtx, dlqCancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer dlqCancel()
			if _, dlqErr := h.publisher.PublishDLQ(dlqCtx, body, errorMessages); dlqErr != nil {
				h.logger.Error().Err(dlqErr).Str("event_type", eventType).Msg("failed to publish to DLQ")
			}
		}()

		respondJSON(w, http.StatusBadRequest, map[string]interface{}{
			"errors":     errorDetails,
			"event_type": eventType,
		})
		return
	}

	h.metrics.EventsValidated.WithLabelValues(eventType, "passed").Inc()

	// Publish to validated topic.
	attrs := map[string]string{
		"event_type": eventType,
		"event_id":   eventID,
		"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
	}

	publishStart := time.Now()
	publishID, err := h.publisher.Publish(r.Context(), body, attrs)
	h.metrics.PublishLatency.WithLabelValues("validated").Observe(time.Since(publishStart).Seconds())

	if err != nil {
		h.metrics.EventsFailed.WithLabelValues(eventType, "publish").Inc()
		h.logger.Error().Err(err).Str("event_type", eventType).Msg("failed to publish event")
		respondError(w, http.StatusBadGateway, "failed to publish event")
		return
	}

	// Write to Bigtable (best-effort: don't fail the request if this errors).
	var eventTimestamp time.Time
	if raw, ok := payload["timestamp"]; ok {
		var tsStr string
		if err := json.Unmarshal(raw, &tsStr); err == nil {
			if parsed, err := time.Parse(time.RFC3339, tsStr); err == nil {
				eventTimestamp = parsed
			}
		}
	}
	if eventTimestamp.IsZero() {
		eventTimestamp = time.Now().UTC()
	}

	btStart := time.Now()
	if err := h.writer.WriteEvent(r.Context(), eventType, eventID, eventTimestamp, body, attrs); err != nil {
		h.logger.Error().Err(err).
			Str("event_type", eventType).
			Str("event_id", eventID).
			Msg("bigtable write failed (best-effort)")
	}
	h.metrics.BigtableWriteLatency.Observe(time.Since(btStart).Seconds())

	respondJSON(w, http.StatusCreated, map[string]interface{}{
		"event_id":   eventID,
		"status":     "accepted",
		"publish_id": publishID,
	})
}

// HandleHealthCheck returns the health status of the service and its dependencies.
func (h *EventHandler) HandleHealthCheck(w http.ResponseWriter, r *http.Request) {
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"status": "healthy",
		"checks": map[string]string{
			"pubsub":   "ok",
			"bigtable": "ok",
		},
	})
}

// respondJSON writes a JSON response with the given status code.
func respondJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		// At this point headers are already sent, so we can only log.
		return
	}
}

// respondError writes a JSON error response.
func respondError(w http.ResponseWriter, status int, message string) {
	respondJSON(w, status, map[string]interface{}{
		"error": message,
	})
}
