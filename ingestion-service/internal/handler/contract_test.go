package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

// The JSON Schemas in schemas/ at the repository root are the contract that
// every message published to the validated Pub/Sub topic must satisfy. The
// ingestion service embeds a copy of them (internal/validator/schemas) because
// go:embed cannot follow symlinks. This file guards both halves of that
// arrangement:
//
//  1. the embedded copies are byte-identical to the canonical schemas, and
//  2. every payload the handler hands to the publisher -- hand-written samples
//     using the "Z" timestamp suffix, and real events produced by
//     scripts/generate_sample_data.py whose timestamps carry microseconds and
//     a "+00:00" offset -- validates against the canonical schema for its type.
//
// It deliberately uses an independent JSON Schema implementation
// (santhosh-tekuri/jsonschema v6, with format assertions enabled) rather than
// the validator package, so a bug in the validator cannot mask a contract
// violation.

const (
	rootSchemaDir     = "../../../schemas"
	embeddedSchemaDir = "../validator/schemas"
	generatorFixture  = "testdata/generator_samples.json"
)

var contractEventTypes = []string{"revenue_transaction", "usage_metric", "cost_record"}

// compileRootSchema compiles schemas/<eventType>.json from the repository root
// with Draft-07 semantics and "format" assertions (uuid, date-time) enabled.
func compileRootSchema(t *testing.T, eventType string) *jsonschema.Schema {
	t.Helper()

	path := filepath.Join(rootSchemaDir, eventType+".json")
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("opening canonical schema %s: %v", path, err)
	}
	defer func() { _ = f.Close() }()

	doc, err := jsonschema.UnmarshalJSON(f)
	if err != nil {
		t.Fatalf("decoding canonical schema %s: %v", path, err)
	}

	c := jsonschema.NewCompiler()
	c.DefaultDraft(jsonschema.Draft7)
	c.AssertFormat()

	url := "file:///contract/" + eventType + ".json"
	if err := c.AddResource(url, doc); err != nil {
		t.Fatalf("adding schema resource %s: %v", url, err)
	}
	sch, err := c.Compile(url)
	if err != nil {
		t.Fatalf("compiling schema %s: %v", path, err)
	}
	return sch
}

// capturingPublisher records every payload handed to Publish / PublishDLQ.
type capturingPublisher struct {
	published [][]byte
	attrs     []map[string]string
	dlq       [][]byte
}

func (c *capturingPublisher) Publish(_ context.Context, data []byte, attrs map[string]string) (string, error) {
	c.published = append(c.published, append([]byte(nil), data...))
	c.attrs = append(c.attrs, attrs)
	return fmt.Sprintf("msg-%d", len(c.published)), nil
}

func (c *capturingPublisher) PublishDLQ(_ context.Context, data []byte, _ []string) (string, error) {
	c.dlq = append(c.dlq, append([]byte(nil), data...))
	return fmt.Sprintf("dlq-%d", len(c.dlq)), nil
}

func (c *capturingPublisher) Stop() {}

// contractSample is one event as a client would send it, tagged with its type.
type contractSample struct {
	name      string
	eventType string
	body      []byte
}

// loadGeneratorSamples reads testdata/generator_samples.json, a verbatim
// excerpt of scripts/generate_sample_data.py output (seed 42).
func loadGeneratorSamples(t *testing.T) []contractSample {
	t.Helper()

	raw, err := os.ReadFile(generatorFixture)
	if err != nil {
		t.Fatalf("reading generator fixture: %v", err)
	}
	var fixture map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decoding generator fixture: %v", err)
	}

	var samples []contractSample
	for _, eventType := range contractEventTypes {
		var events []json.RawMessage
		if err := json.Unmarshal(fixture[eventType], &events); err != nil {
			t.Fatalf("decoding %s fixture events: %v", eventType, err)
		}
		if len(events) == 0 {
			t.Fatalf("generator fixture has no %s events", eventType)
		}
		for i, ev := range events {
			samples = append(samples, contractSample{
				name:      fmt.Sprintf("generator/%s/%d", eventType, i),
				eventType: eventType,
				body:      ev,
			})
		}
	}
	return samples
}

// handWrittenSamples mirrors the payloads used elsewhere in the test suite and
// the README, plus the same payloads with generator-style timestamps.
func handWrittenSamples() []contractSample {
	base := []contractSample{
		{name: "handwritten/revenue_transaction/Z", eventType: "revenue_transaction", body: validRevenueJSON()},
		{name: "handwritten/usage_metric/Z", eventType: "usage_metric", body: validUsageJSON()},
		{name: "handwritten/cost_record/Z", eventType: "cost_record", body: validCostJSON()},
	}

	// Python's datetime.isoformat() form: microseconds and a numeric offset.
	generatorTS := "2025-01-15T10:30:00.123456+00:00"
	var withOffset []contractSample
	for _, s := range base {
		withOffset = append(withOffset, contractSample{
			name:      strings.Replace(s.name, "/Z", "/fractional+00:00", 1),
			eventType: s.eventType,
			body:      bytes.Replace(s.body, []byte("2025-01-15T10:30:00Z"), []byte(generatorTS), 1),
		})
	}
	return append(base, withOffset...)
}

// withEmbeddedEventType returns the body with an "event_type" field added, the
// alternative to the ?type= query parameter.
func withEmbeddedEventType(t *testing.T, sample contractSample) []byte {
	t.Helper()

	var m map[string]json.RawMessage
	if err := json.Unmarshal(sample.body, &m); err != nil {
		t.Fatalf("%s: decoding sample: %v", sample.name, err)
	}
	m["event_type"] = json.RawMessage(fmt.Sprintf("%q", sample.eventType))
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("%s: encoding sample: %v", sample.name, err)
	}
	return out
}

func TestContract_EmbeddedSchemasMatchCanonical(t *testing.T) {
	for _, eventType := range contractEventTypes {
		t.Run(eventType, func(t *testing.T) {
			canonical, err := os.ReadFile(filepath.Join(rootSchemaDir, eventType+".json"))
			if err != nil {
				t.Fatalf("reading canonical schema: %v", err)
			}
			embedded, err := os.ReadFile(filepath.Join(embeddedSchemaDir, eventType+".json"))
			if err != nil {
				t.Fatalf("reading embedded schema: %v", err)
			}
			if !bytes.Equal(canonical, embedded) {
				t.Fatalf("embedded schema %s has drifted from schemas/%s.json; copy the canonical file over it",
					eventType, eventType)
			}
		})
	}
}

func TestContract_PublishedEventsValidateAgainstSchemas(t *testing.T) {
	schemas := make(map[string]*jsonschema.Schema, len(contractEventTypes))
	for _, eventType := range contractEventTypes {
		schemas[eventType] = compileRootSchema(t, eventType)
	}

	samples := append(handWrittenSamples(), loadGeneratorSamples(t)...)

	modes := []struct {
		name  string
		build func(t *testing.T, s contractSample) (url string, body []byte)
	}{
		{
			name: "type-query-param",
			build: func(_ *testing.T, s contractSample) (string, []byte) {
				return "/api/v1/events?type=" + s.eventType, s.body
			},
		},
		{
			name: "event_type-field",
			build: func(t *testing.T, s contractSample) (string, []byte) {
				return "/api/v1/events", withEmbeddedEventType(t, s)
			},
		},
	}

	for _, sample := range samples {
		for _, mode := range modes {
			t.Run(sample.name+"/"+mode.name, func(t *testing.T) {
				pub := &capturingPublisher{}
				var writtenTS time.Time
				writer := &mockWriter{
					writeFunc: func(_ context.Context, _, _ string, ts time.Time, _ []byte, _ map[string]string) error {
						writtenTS = ts
						return nil
					},
				}
				h := NewEventHandler(pub, writer, newTestHandler(nil, nil).metrics, newTestHandler(nil, nil).logger)

				url, body := mode.build(t, sample)
				req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(body))
				req.Header.Set("Content-Type", "application/json")
				rec := httptest.NewRecorder()

				h.HandleIngestEvent(rec, req)

				if rec.Code != http.StatusCreated {
					t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
				}
				if len(pub.dlq) != 0 {
					t.Fatalf("valid event was sent to the DLQ: %s", pub.dlq[0])
				}
				if len(pub.published) != 1 {
					t.Fatalf("expected exactly one published message, got %d", len(pub.published))
				}
				if got := pub.attrs[0]["event_type"]; got != sample.eventType {
					t.Errorf("event_type attribute: got %q, want %q", got, sample.eventType)
				}

				// The published payload must validate against the canonical schema.
				doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(pub.published[0]))
				if err != nil {
					t.Fatalf("published payload is not JSON: %v", err)
				}
				if err := schemas[sample.eventType].Validate(doc); err != nil {
					t.Fatalf("published payload violates schemas/%s.json:\n%v\npayload: %s",
						sample.eventType, err, pub.published[0])
				}

				// The transport-only event_type field must never leak onto the topic.
				var published map[string]json.RawMessage
				if err := json.Unmarshal(pub.published[0], &published); err != nil {
					t.Fatalf("decoding published payload: %v", err)
				}
				if _, leaked := published["event_type"]; leaked {
					t.Errorf("published payload contains event_type, which the schema forbids")
				}

				// The event's own timestamp (not the wall clock) must drive the row key.
				if writtenTS.Year() != 2025 {
					t.Errorf("Bigtable write used timestamp %v; expected the event's 2025 timestamp to be parsed", writtenTS)
				}
			})
		}
	}
}

func TestContract_SchemasRejectMalformedTimestamps(t *testing.T) {
	// Sanity check that format assertions are actually on: a syntactically
	// valid string that is not RFC 3339 must fail the canonical schema.
	sch := compileRootSchema(t, "revenue_transaction")
	bad := bytes.Replace(validRevenueJSON(), []byte("2025-01-15T10:30:00Z"), []byte("15/01/2025 10:30"), 1)
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(bad))
	if err != nil {
		t.Fatalf("decoding sample: %v", err)
	}
	if err := sch.Validate(doc); err == nil {
		t.Fatal("expected date-time format violation, got none")
	}
}
