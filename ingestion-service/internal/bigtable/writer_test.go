package bigtable

import (
	"context"
	"fmt"
	"math"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/bigtable"
)

const (
	testProjectID  = "test-project"
	testInstanceID = "test-instance"
	testTableID    = "events"
)

func skipIfNoEmulator(t *testing.T) {
	t.Helper()
	if os.Getenv("BIGTABLE_EMULATOR_HOST") == "" {
		t.Skip("BIGTABLE_EMULATOR_HOST not set; skipping Bigtable emulator test")
	}
}

// setupTestTable creates the test table and column families in the Bigtable emulator.
func setupTestTable(ctx context.Context, t *testing.T, tableID string) {
	t.Helper()

	adminClient, err := bigtable.NewAdminClient(ctx, testProjectID, testInstanceID)
	if err != nil {
		t.Fatalf("creating admin client: %v", err)
	}
	defer func() { _ = adminClient.Close() }()

	// Attempt to create; ignore error if it already exists.
	_ = adminClient.CreateTable(ctx, tableID)

	for _, cf := range []string{cfEventData, cfMetadata, cfProcessingStatus} {
		_ = adminClient.CreateColumnFamily(ctx, tableID, cf)
	}
}

func TestRowKey_Format(t *testing.T) {
	ts := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)
	eventType := "revenue_transaction"
	eventID := "abc-123"

	key := RowKey(eventType, ts, eventID)

	expectedReverseTS := math.MaxInt64 - ts.UnixMilli()
	expected := fmt.Sprintf("revenue_transaction#%013d#abc-123", expectedReverseTS)

	if key != expected {
		t.Errorf("row key mismatch:\n  got:  %s\n  want: %s", key, expected)
	}
}

func TestRowKey_ReverseChronological(t *testing.T) {
	earlier := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	later := time.Date(2025, 6, 1, 0, 0, 0, 0, time.UTC)

	keyEarlier := RowKey("revenue_transaction", earlier, "id-1")
	keyLater := RowKey("revenue_transaction", later, "id-2")

	// Later timestamps should sort BEFORE earlier ones (reverse chronological).
	if keyLater >= keyEarlier {
		t.Errorf("expected later timestamp key (%s) to sort before earlier key (%s)", keyLater, keyEarlier)
	}
}

func TestBigTableWriter_WriteAndRead(t *testing.T) {
	skipIfNoEmulator(t)
	ctx := context.Background()

	tableID := "events-write-test"
	setupTestTable(ctx, t, tableID)

	writer, err := NewBigTableWriter(ctx, testProjectID, testInstanceID, tableID)
	if err != nil {
		t.Fatalf("creating writer: %v", err)
	}
	defer func() { _ = writer.Close() }()

	ts := time.Date(2025, 1, 15, 10, 30, 0, 0, time.UTC)
	eventData := []byte(`{"transaction_id":"abc-123","amount_cents":1500}`)
	metadata := map[string]string{
		"customer_id":  "cust-001",
		"product_line": "api_usage",
		"region":       "us-east",
	}

	err = writer.WriteEvent(ctx, "revenue_transaction", "abc-123", ts, eventData, metadata)
	if err != nil {
		t.Fatalf("writing event: %v", err)
	}

	// Read back and verify.
	rowKey := RowKey("revenue_transaction", ts, "abc-123")
	row, err := writer.table.ReadRow(ctx, rowKey)
	if err != nil {
		t.Fatalf("reading row: %v", err)
	}

	if len(row) == 0 {
		t.Fatal("expected row to exist")
	}

	// Verify event_data.
	rawItems := row[cfEventData]
	if len(rawItems) == 0 {
		t.Fatal("expected event_data column family to have data")
	}
	if string(rawItems[0].Value) != string(eventData) {
		t.Errorf("event data mismatch: got %q, want %q", rawItems[0].Value, eventData)
	}

	// Verify metadata columns.
	metaItems := row[cfMetadata]
	metaMap := make(map[string]string)
	for _, item := range metaItems {
		// Column qualifier is "metadata:<key>", extract key portion.
		col := item.Column
		// Remove family prefix.
		for i, c := range col {
			if c == ':' {
				col = col[i+1:]
				break
			}
		}
		metaMap[col] = string(item.Value)
	}
	for k, v := range metadata {
		if metaMap[k] != v {
			t.Errorf("metadata[%s]: got %q, want %q", k, metaMap[k], v)
		}
	}

	// Verify processing_status.
	statusItems := row[cfProcessingStatus]
	if len(statusItems) == 0 {
		t.Fatal("expected processing_status column family to have data")
	}
}

func TestBigTableWriter_Idempotent(t *testing.T) {
	skipIfNoEmulator(t)
	ctx := context.Background()

	tableID := "events-idempotent-test"
	setupTestTable(ctx, t, tableID)

	writer, err := NewBigTableWriter(ctx, testProjectID, testInstanceID, tableID)
	if err != nil {
		t.Fatalf("creating writer: %v", err)
	}
	defer func() { _ = writer.Close() }()

	ts := time.Date(2025, 2, 1, 12, 0, 0, 0, time.UTC)
	originalData := []byte(`{"transaction_id":"idempotent-1","amount_cents":1000}`)
	updatedData := []byte(`{"transaction_id":"idempotent-1","amount_cents":9999}`)

	// First write should succeed.
	err = writer.WriteEvent(ctx, "revenue_transaction", "idempotent-1", ts, originalData, map[string]string{"customer_id": "cust-001"})
	if err != nil {
		t.Fatalf("first write: %v", err)
	}

	// Second write with different data should be a no-op (conditional mutation).
	err = writer.WriteEvent(ctx, "revenue_transaction", "idempotent-1", ts, updatedData, map[string]string{"customer_id": "cust-002"})
	if err != nil {
		t.Fatalf("second write: %v", err)
	}

	// Verify original data is preserved.
	rowKey := RowKey("revenue_transaction", ts, "idempotent-1")
	row, err := writer.table.ReadRow(ctx, rowKey)
	if err != nil {
		t.Fatalf("reading row: %v", err)
	}

	rawItems := row[cfEventData]
	if len(rawItems) == 0 {
		t.Fatal("expected event_data to exist")
	}
	if string(rawItems[0].Value) != string(originalData) {
		t.Errorf("idempotency failed: data was overwritten.\n  got:  %s\n  want: %s", rawItems[0].Value, originalData)
	}
}

func TestBigTableWriter_ColumnFamilies(t *testing.T) {
	skipIfNoEmulator(t)
	ctx := context.Background()

	tableID := "events-cf-test"
	setupTestTable(ctx, t, tableID)

	writer, err := NewBigTableWriter(ctx, testProjectID, testInstanceID, tableID)
	if err != nil {
		t.Fatalf("creating writer: %v", err)
	}
	defer func() { _ = writer.Close() }()

	ts := time.Date(2025, 3, 1, 8, 0, 0, 0, time.UTC)
	err = writer.WriteEvent(ctx, "usage_metric", "metric-001", ts, []byte(`{"metric_id":"metric-001"}`), map[string]string{
		"customer_id": "cust-100",
		"metric_type": "api_calls",
	})
	if err != nil {
		t.Fatalf("writing event: %v", err)
	}

	rowKey := RowKey("usage_metric", ts, "metric-001")
	row, err := writer.table.ReadRow(ctx, rowKey)
	if err != nil {
		t.Fatalf("reading row: %v", err)
	}

	// Check all three column families are present.
	expectedFamilies := []string{cfEventData, cfMetadata, cfProcessingStatus}
	for _, cf := range expectedFamilies {
		if _, ok := row[cf]; !ok {
			t.Errorf("expected column family %q to be present in row", cf)
		}
	}
}
