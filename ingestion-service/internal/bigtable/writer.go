// Package bigtable provides event storage in Google Cloud Bigtable for hot-path queries.
package bigtable

import (
	"context"
	"fmt"
	"math"
	"time"

	"cloud.google.com/go/bigtable"
)

const (
	// Column family names used in the events table.
	cfEventData        = "event_data"
	cfMetadata         = "metadata"
	cfProcessingStatus = "processing_status"

	// Column names within event_data.
	colRaw = "raw"

	// Column names within processing_status.
	colReceivedAt  = "received_at"
	colValidatedAt = "validated_at"
)

// EventWriter defines the interface for writing events to the hot-path store.
type EventWriter interface {
	WriteEvent(ctx context.Context, eventType, eventID string, timestamp time.Time, data []byte, metadata map[string]string) error
	Close() error
}

// BigTableWriter implements EventWriter using Google Cloud Bigtable.
type BigTableWriter struct {
	client *bigtable.Client
	table  *bigtable.Table
}

// NewBigTableWriter creates a new BigTableWriter connected to the specified
// Bigtable instance and table. It validates the connection by opening the client.
func NewBigTableWriter(ctx context.Context, projectID, instanceID, tableID string) (*BigTableWriter, error) {
	client, err := bigtable.NewClient(ctx, projectID, instanceID)
	if err != nil {
		return nil, fmt.Errorf("creating bigtable client: %w", err)
	}

	return &BigTableWriter{
		client: client,
		table:  client.Open(tableID),
	}, nil
}

// RowKey constructs a Bigtable row key that sorts events in reverse chronological
// order within each event type. The reverse timestamp is zero-padded to 13 digits
// for consistent lexicographic ordering.
func RowKey(eventType string, timestamp time.Time, eventID string) string {
	reverseTS := math.MaxInt64 - timestamp.UnixMilli()
	return fmt.Sprintf("%s#%013d#%s", eventType, reverseTS, eventID)
}

// WriteEvent stores an event in Bigtable. It uses a conditional mutation to ensure
// idempotency: the write only succeeds if the row does not already exist.
func (w *BigTableWriter) WriteEvent(ctx context.Context, eventType, eventID string, timestamp time.Time, data []byte, metadata map[string]string) error {
	rowKey := RowKey(eventType, timestamp, eventID)
	now := time.Now().UTC().Format(time.RFC3339Nano)

	mut := bigtable.NewMutation()

	// event_data column family: store the full JSON payload.
	mut.Set(cfEventData, colRaw, bigtable.Now(), data)

	// metadata column family: one column per metadata key.
	for k, v := range metadata {
		mut.Set(cfMetadata, k, bigtable.Now(), []byte(v))
	}

	// processing_status column family: timestamps for tracking.
	mut.Set(cfProcessingStatus, colReceivedAt, bigtable.Now(), []byte(now))
	mut.Set(cfProcessingStatus, colValidatedAt, bigtable.Now(), []byte(now))

	// Conditional mutation: only write if the row does not already exist.
	// The filter checks for any cells in the event_data family. If found,
	// the row exists and the write is skipped (idempotent).
	filter := bigtable.ChainFilters(
		bigtable.FamilyFilter(cfEventData),
		bigtable.ColumnFilter(colRaw),
		bigtable.LatestNFilter(1),
	)
	conditionalMut := bigtable.NewCondMutation(filter, nil, mut)

	if err := w.table.Apply(ctx, rowKey, conditionalMut); err != nil {
		return fmt.Errorf("applying bigtable mutation for row %s: %w", rowKey, err)
	}

	return nil
}

// Close releases the Bigtable client resources.
func (w *BigTableWriter) Close() error {
	if err := w.client.Close(); err != nil {
		return fmt.Errorf("closing bigtable client: %w", err)
	}
	return nil
}
