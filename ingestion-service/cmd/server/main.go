// Package main is the entrypoint for the ingestion service HTTP server.
package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/rs/zerolog"

	btwriter "github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/bigtable"
	"github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/handler"
	"github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/metrics"
	"github.com/adesolanke/gcp-financial-data-platform/ingestion-service/internal/publisher"
)

func main() {
	// Load configuration from environment.
	cfg := loadConfig()

	// Initialize structured logger.
	level, err := zerolog.ParseLevel(cfg.logLevel)
	if err != nil {
		level = zerolog.InfoLevel
	}
	logger := zerolog.New(os.Stdout).
		Level(level).
		With().
		Timestamp().
		Str("service", "ingestion-service").
		Logger()

	ctx := context.Background()

	// Initialize Pub/Sub publisher.
	pub, err := publisher.NewPubSubPublisher(ctx, cfg.pubsubProjectID, cfg.pubsubTopicValidated, cfg.pubsubTopicDLQ)
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to initialize pubsub publisher")
	}
	logger.Info().
		Str("project", cfg.pubsubProjectID).
		Str("topic_validated", cfg.pubsubTopicValidated).
		Str("topic_dlq", cfg.pubsubTopicDLQ).
		Msg("pubsub publisher initialized")

	// Initialize Bigtable writer.
	writer, err := btwriter.NewBigTableWriter(ctx, cfg.bigtableProjectID, cfg.bigtableInstanceID, cfg.bigtableTableID)
	if err != nil {
		logger.Fatal().Err(err).Msg("failed to initialize bigtable writer")
	}
	logger.Info().
		Str("project", cfg.bigtableProjectID).
		Str("instance", cfg.bigtableInstanceID).
		Str("table", cfg.bigtableTableID).
		Msg("bigtable writer initialized")

	// Initialize metrics.
	m := metrics.NewMetrics()

	// Initialize handler.
	h := handler.NewEventHandler(pub, writer, m, logger)

	// Build router.
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(zerologMiddleware(logger))
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(60 * time.Second))

	r.Get("/healthz", h.HandleHealthCheck)
	r.Get("/metrics", promhttp.Handler().ServeHTTP)
	r.Post("/api/v1/events", h.HandleIngestEvent)

	// Start server.
	srv := &http.Server{
		Addr:         fmt.Sprintf(":%s", cfg.port),
		Handler:      r,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Graceful shutdown.
	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		logger.Info().Str("addr", srv.Addr).Msg("server starting")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal().Err(err).Msg("server failed")
		}
	}()

	sig := <-shutdown
	logger.Info().Str("signal", sig.String()).Msg("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// 1. Drain in-flight HTTP requests.
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error().Err(err).Msg("http server shutdown error")
	}

	// 2. Flush Pub/Sub pending messages.
	pub.Stop()
	logger.Info().Msg("pubsub publisher stopped")

	// 3. Close Bigtable connection.
	if err := writer.Close(); err != nil {
		logger.Error().Err(err).Msg("bigtable writer close error")
	}
	logger.Info().Msg("bigtable writer closed")

	logger.Info().Msg("server stopped")
}

// config holds all service configuration loaded from the environment.
type config struct {
	port                 string
	logLevel             string
	pubsubProjectID      string
	pubsubTopicValidated string
	pubsubTopicDLQ       string
	bigtableProjectID    string
	bigtableInstanceID   string
	bigtableTableID      string
}

// loadConfig reads configuration from environment variables with sensible defaults.
func loadConfig() config {
	return config{
		port:                 envOrDefault("PORT", "8080"),
		logLevel:             envOrDefault("LOG_LEVEL", "info"),
		pubsubProjectID:      envOrDefault("PUBSUB_PROJECT_ID", ""),
		pubsubTopicValidated: envOrDefault("PUBSUB_TOPIC_VALIDATED", "validated-events"),
		pubsubTopicDLQ:       envOrDefault("PUBSUB_TOPIC_DLQ", "dlq-events"),
		bigtableProjectID:    envOrDefault("BIGTABLE_PROJECT_ID", ""),
		bigtableInstanceID:   envOrDefault("BIGTABLE_INSTANCE_ID", ""),
		bigtableTableID:      envOrDefault("BIGTABLE_TABLE_ID", "events"),
	}
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// zerologMiddleware returns chi-compatible request logging middleware using zerolog.
func zerologMiddleware(logger zerolog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)

			defer func() {
				logger.Info().
					Str("method", r.Method).
					Str("path", r.URL.Path).
					Int("status", ww.Status()).
					Int("bytes", ww.BytesWritten()).
					Dur("latency", time.Since(start)).
					Str("request_id", middleware.GetReqID(r.Context())).
					Msg("request completed")
			}()

			next.ServeHTTP(ww, r)
		})
	}
}
