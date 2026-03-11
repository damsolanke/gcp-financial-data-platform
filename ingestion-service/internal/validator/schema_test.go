package validator

import (
	"encoding/json"
	"fmt"
	"testing"
)

// validRevenueTransaction returns a valid revenue_transaction event as a map.
func validRevenueTransaction() map[string]interface{} {
	return map[string]interface{}{
		"transaction_id": "550e8400-e29b-41d4-a716-446655440000",
		"timestamp":      "2025-01-15T10:30:00Z",
		"amount_cents":   1500,
		"currency":       "USD",
		"customer_id":    "cust-12345",
		"product_line":   "api_usage",
		"region":         "us-east",
	}
}

// validUsageMetric returns a valid usage_metric event as a map.
func validUsageMetric() map[string]interface{} {
	return map[string]interface{}{
		"metric_id":   "660e8400-e29b-41d4-a716-446655440001",
		"timestamp":   "2025-01-15T10:30:00Z",
		"customer_id": "cust-12345",
		"metric_type": "api_calls",
		"quantity":    100,
		"unit":        "calls",
	}
}

// validCostRecord returns a valid cost_record event as a map.
func validCostRecord() map[string]interface{} {
	return map[string]interface{}{
		"record_id":   "770e8400-e29b-41d4-a716-446655440002",
		"timestamp":   "2025-01-15T10:30:00Z",
		"cost_center": "engineering",
		"category":    "compute",
		"amount_cents": 50000,
		"currency":    "USD",
	}
}

func mustJSON(t *testing.T, v interface{}) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshalling test data: %v", err)
	}
	return data
}

func TestValidateEvent_ValidEvents(t *testing.T) {
	tests := []struct {
		name      string
		eventType string
		event     map[string]interface{}
	}{
		{
			name:      "valid revenue_transaction",
			eventType: "revenue_transaction",
			event:     validRevenueTransaction(),
		},
		{
			name:      "valid usage_metric",
			eventType: "usage_metric",
			event:     validUsageMetric(),
		},
		{
			name:      "valid cost_record",
			eventType: "cost_record",
			event:     validCostRecord(),
		},
		{
			name:      "revenue_transaction with optional metadata",
			eventType: "revenue_transaction",
			event: func() map[string]interface{} {
				e := validRevenueTransaction()
				e["metadata"] = map[string]interface{}{"invoice_id": "INV-001"}
				return e
			}(),
		},
		{
			name:      "cost_record with optional vendor and description",
			eventType: "cost_record",
			event: func() map[string]interface{} {
				e := validCostRecord()
				e["vendor"] = "AWS"
				e["description"] = "Monthly compute costs"
				return e
			}(),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			errs, err := ValidateEvent(tt.eventType, mustJSON(t, tt.event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) > 0 {
				t.Fatalf("expected no validation errors, got %d: %+v", len(errs), errs)
			}
		})
	}
}

func TestValidateEvent_MissingRequiredFields(t *testing.T) {
	revenueRequired := []string{
		"transaction_id", "timestamp", "amount_cents", "currency",
		"customer_id", "product_line", "region",
	}
	for _, field := range revenueRequired {
		t.Run(fmt.Sprintf("revenue_transaction missing %s", field), func(t *testing.T) {
			event := validRevenueTransaction()
			delete(event, field)
			errs, err := ValidateEvent("revenue_transaction", mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatalf("expected validation error for missing %s", field)
			}
			found := false
			for _, e := range errs {
				if e.Field == field || e.Type == "required" {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("expected error referencing field %q, got: %+v", field, errs)
			}
		})
	}

	usageRequired := []string{
		"metric_id", "timestamp", "customer_id", "metric_type", "quantity", "unit",
	}
	for _, field := range usageRequired {
		t.Run(fmt.Sprintf("usage_metric missing %s", field), func(t *testing.T) {
			event := validUsageMetric()
			delete(event, field)
			errs, err := ValidateEvent("usage_metric", mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatalf("expected validation error for missing %s", field)
			}
		})
	}

	costRequired := []string{
		"record_id", "timestamp", "cost_center", "category", "amount_cents", "currency",
	}
	for _, field := range costRequired {
		t.Run(fmt.Sprintf("cost_record missing %s", field), func(t *testing.T) {
			event := validCostRecord()
			delete(event, field)
			errs, err := ValidateEvent("cost_record", mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatalf("expected validation error for missing %s", field)
			}
		})
	}
}

func TestValidateEvent_InvalidEnumValues(t *testing.T) {
	tests := []struct {
		name      string
		eventType string
		mutate    func(map[string]interface{})
	}{
		{
			name:      "invalid product_line",
			eventType: "revenue_transaction",
			mutate:    func(e map[string]interface{}) { e["product_line"] = "unknown_product" },
		},
		{
			name:      "invalid region",
			eventType: "revenue_transaction",
			mutate:    func(e map[string]interface{}) { e["region"] = "mars-central" },
		},
		{
			name:      "invalid metric_type",
			eventType: "usage_metric",
			mutate:    func(e map[string]interface{}) { e["metric_type"] = "disk_io" },
		},
		{
			name:      "invalid category",
			eventType: "cost_record",
			mutate:    func(e map[string]interface{}) { e["category"] = "marketing" },
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var event map[string]interface{}
			switch tt.eventType {
			case "revenue_transaction":
				event = validRevenueTransaction()
			case "usage_metric":
				event = validUsageMetric()
			case "cost_record":
				event = validCostRecord()
			}
			tt.mutate(event)
			errs, err := ValidateEvent(tt.eventType, mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatal("expected validation error for invalid enum value")
			}
		})
	}
}

func TestValidateEvent_WrongTypes(t *testing.T) {
	tests := []struct {
		name      string
		eventType string
		mutate    func(map[string]interface{})
	}{
		{
			name:      "amount_cents as string instead of integer",
			eventType: "revenue_transaction",
			mutate:    func(e map[string]interface{}) { e["amount_cents"] = "not-a-number" },
		},
		{
			name:      "quantity as string instead of number",
			eventType: "usage_metric",
			mutate:    func(e map[string]interface{}) { e["quantity"] = "many" },
		},
		{
			name:      "timestamp as integer instead of string",
			eventType: "revenue_transaction",
			mutate:    func(e map[string]interface{}) { e["timestamp"] = 12345 },
		},
		{
			name:      "customer_id as integer instead of string",
			eventType: "usage_metric",
			mutate:    func(e map[string]interface{}) { e["customer_id"] = 12345 },
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var event map[string]interface{}
			switch tt.eventType {
			case "revenue_transaction":
				event = validRevenueTransaction()
			case "usage_metric":
				event = validUsageMetric()
			}
			tt.mutate(event)
			errs, err := ValidateEvent(tt.eventType, mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatal("expected validation error for wrong type")
			}
		})
	}
}

func TestValidateEvent_AmountCentsNotPositive(t *testing.T) {
	tests := []struct {
		name  string
		value interface{}
	}{
		{"amount_cents zero", 0},
		{"amount_cents negative", -100},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := validRevenueTransaction()
			event["amount_cents"] = tt.value
			errs, err := ValidateEvent("revenue_transaction", mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatal("expected validation error for non-positive amount_cents")
			}
		})
	}
}

func TestValidateEvent_QuantityNegative(t *testing.T) {
	event := validUsageMetric()
	event["quantity"] = -1
	errs, err := ValidateEvent("usage_metric", mustJSON(t, event))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(errs) == 0 {
		t.Fatal("expected validation error for negative quantity")
	}
}

func TestValidateEvent_EmptyRequiredStrings(t *testing.T) {
	tests := []struct {
		name      string
		eventType string
		field     string
	}{
		{"empty customer_id in revenue", "revenue_transaction", "customer_id"},
		{"empty customer_id in usage", "usage_metric", "customer_id"},
		{"empty unit in usage", "usage_metric", "unit"},
		{"empty cost_center in cost", "cost_record", "cost_center"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var event map[string]interface{}
			switch tt.eventType {
			case "revenue_transaction":
				event = validRevenueTransaction()
			case "usage_metric":
				event = validUsageMetric()
			case "cost_record":
				event = validCostRecord()
			}
			event[tt.field] = ""
			errs, err := ValidateEvent(tt.eventType, mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatalf("expected validation error for empty %s", tt.field)
			}
		})
	}
}

func TestValidateEvent_InvalidCurrencyPattern(t *testing.T) {
	tests := []struct {
		name  string
		value string
	}{
		{"lowercase", "usd"},
		{"too short", "US"},
		{"too long", "USDX"},
		{"digits", "123"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := validRevenueTransaction()
			event["currency"] = tt.value
			errs, err := ValidateEvent("revenue_transaction", mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatalf("expected validation error for currency %q", tt.value)
			}
		})
	}
}

func TestValidateEvent_ExtraFieldsRejected(t *testing.T) {
	tests := []struct {
		name      string
		eventType string
	}{
		{"revenue_transaction extra field", "revenue_transaction"},
		{"usage_metric extra field", "usage_metric"},
		{"cost_record extra field", "cost_record"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var event map[string]interface{}
			switch tt.eventType {
			case "revenue_transaction":
				event = validRevenueTransaction()
			case "usage_metric":
				event = validUsageMetric()
			case "cost_record":
				event = validCostRecord()
			}
			event["unexpected_field"] = "surprise"
			errs, err := ValidateEvent(tt.eventType, mustJSON(t, event))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(errs) == 0 {
				t.Fatal("expected validation error for additional property")
			}
			found := false
			for _, e := range errs {
				if e.Type == "additional_property_not_allowed" {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("expected additional_property_not_allowed error, got: %+v", errs)
			}
		})
	}
}

func TestValidateEvent_UnknownEventType(t *testing.T) {
	_, err := ValidateEvent("unknown_type", []byte(`{}`))
	if err == nil {
		t.Fatal("expected error for unknown event type")
	}
}

func TestValidateEvent_InvalidJSON(t *testing.T) {
	_, err := ValidateEvent("revenue_transaction", []byte(`{not json`))
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func BenchmarkValidateRevenueTransaction(b *testing.B) {
	event := validRevenueTransaction()
	data, err := json.Marshal(event)
	if err != nil {
		b.Fatalf("marshalling benchmark data: %v", err)
	}

	// Warm up schema loading.
	if _, err := ValidateEvent("revenue_transaction", data); err != nil {
		b.Fatalf("warming up validator: %v", err)
	}

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		errs, err := ValidateEvent("revenue_transaction", data)
		if err != nil {
			b.Fatalf("validation error: %v", err)
		}
		if len(errs) > 0 {
			b.Fatalf("unexpected validation errors: %+v", errs)
		}
	}
}
