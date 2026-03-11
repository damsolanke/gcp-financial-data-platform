// Package validator provides JSON schema validation for financial event types.
//
// The schema files in the schemas/ subdirectory are copies of the canonical schemas
// defined in the repository root at ../../schemas/. They are copied here because
// Go's //go:embed directive does not follow symlinks. When updating schemas, ensure
// both locations are kept in sync.
package validator

import (
	"embed"
	"fmt"
	"sync"

	"github.com/xeipuuv/gojsonschema"
)

//go:embed schemas/*.json
var schemaFS embed.FS

// ValidationError represents a single validation failure for a specific field.
type ValidationError struct {
	Field   string `json:"field"`
	Message string `json:"message"`
	Type    string `json:"type"`
}

// supportedEventTypes enumerates the event types recognized by the validator.
var supportedEventTypes = map[string]string{
	"revenue_transaction": "schemas/revenue_transaction.json",
	"usage_metric":        "schemas/usage_metric.json",
	"cost_record":         "schemas/cost_record.json",
}

// compiledSchemas holds pre-compiled JSON schemas keyed by event type.
var (
	compiledSchemas map[string]*gojsonschema.Schema
	schemasOnce     sync.Once
	schemasErr      error
)

// loadSchemas compiles all embedded JSON schemas exactly once.
func loadSchemas() error {
	schemasOnce.Do(func() {
		compiledSchemas = make(map[string]*gojsonschema.Schema, len(supportedEventTypes))
		for eventType, path := range supportedEventTypes {
			raw, err := schemaFS.ReadFile(path)
			if err != nil {
				schemasErr = fmt.Errorf("reading embedded schema %s: %w", path, err)
				return
			}
			loader := gojsonschema.NewBytesLoader(raw)
			schema, err := gojsonschema.NewSchema(loader)
			if err != nil {
				schemasErr = fmt.Errorf("compiling schema for %s: %w", eventType, err)
				return
			}
			compiledSchemas[eventType] = schema
		}
	})
	return schemasErr
}

// ValidateEvent validates the given JSON payload against the schema for eventType.
// It returns a slice of validation errors (empty if valid) or an error if the
// event type is unknown or schemas failed to load.
func ValidateEvent(eventType string, data []byte) ([]ValidationError, error) {
	if err := loadSchemas(); err != nil {
		return nil, fmt.Errorf("loading schemas: %w", err)
	}

	schema, ok := compiledSchemas[eventType]
	if !ok {
		return nil, fmt.Errorf("unknown event type: %q", eventType)
	}

	documentLoader := gojsonschema.NewBytesLoader(data)
	result, err := schema.Validate(documentLoader)
	if err != nil {
		return nil, fmt.Errorf("validating JSON document: %w", err)
	}

	if result.Valid() {
		return nil, nil
	}

	errs := make([]ValidationError, 0, len(result.Errors()))
	for _, desc := range result.Errors() {
		field := desc.Field()
		if field == "(root)" {
			// Use the property name from the details when available.
			if prop, ok := desc.Details()["property"]; ok {
				field = fmt.Sprintf("%v", prop)
			}
		}
		errs = append(errs, ValidationError{
			Field:   field,
			Message: desc.Description(),
			Type:    desc.Type(),
		})
	}

	return errs, nil
}

// SupportedEventTypes returns the set of event types the validator recognizes.
func SupportedEventTypes() []string {
	types := make([]string, 0, len(supportedEventTypes))
	for t := range supportedEventTypes {
		types = append(types, t)
	}
	return types
}
