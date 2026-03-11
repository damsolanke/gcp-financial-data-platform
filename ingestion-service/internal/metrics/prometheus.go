// Package metrics provides Prometheus instrumentation for the ingestion service.
package metrics

import (
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics holds all Prometheus collectors for the ingestion service.
type Metrics struct {
	EventsReceived       *prometheus.CounterVec
	EventsValidated      *prometheus.CounterVec
	EventsFailed         *prometheus.CounterVec
	ValidationLatency    *prometheus.HistogramVec
	PublishLatency       *prometheus.HistogramVec
	BigtableWriteLatency prometheus.Histogram
}

var (
	instance *Metrics
	once     sync.Once
)

// NewMetrics returns the singleton Metrics instance, creating and registering
// all Prometheus collectors on first call. Subsequent calls return the same
// instance — this avoids duplicate registration panics in tests.
func NewMetrics() *Metrics {
	once.Do(func() {
		instance = &Metrics{
			EventsReceived: promauto.NewCounterVec(
				prometheus.CounterOpts{
					Name: "ingestion_events_received_total",
					Help: "Total number of events received by the ingestion service.",
				},
				[]string{"event_type"},
			),
			EventsValidated: promauto.NewCounterVec(
				prometheus.CounterOpts{
					Name: "ingestion_events_validated_total",
					Help: "Total number of events that passed or failed validation.",
				},
				[]string{"event_type", "result"},
			),
			EventsFailed: promauto.NewCounterVec(
				prometheus.CounterOpts{
					Name: "ingestion_events_failed_total",
					Help: "Total number of events that failed processing.",
				},
				[]string{"event_type", "error_type"},
			),
			ValidationLatency: promauto.NewHistogramVec(
				prometheus.HistogramOpts{
					Name:    "ingestion_validation_latency_seconds",
					Help:    "Time spent validating events.",
					Buckets: prometheus.DefBuckets,
				},
				[]string{"event_type"},
			),
			PublishLatency: promauto.NewHistogramVec(
				prometheus.HistogramOpts{
					Name:    "ingestion_publish_latency_seconds",
					Help:    "Time spent publishing events to Pub/Sub.",
					Buckets: prometheus.DefBuckets,
				},
				[]string{"topic"},
			),
			BigtableWriteLatency: promauto.NewHistogram(
				prometheus.HistogramOpts{
					Name:    "ingestion_bigtable_write_latency_seconds",
					Help:    "Time spent writing events to Bigtable.",
					Buckets: prometheus.DefBuckets,
				},
			),
		}
	})
	return instance
}
