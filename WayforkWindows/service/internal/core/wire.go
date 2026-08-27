package core

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"
)

const wireTimestampLayout = "2006-01-02T15:04:05Z"

// Timestamp is the whole-second UTC timestamp used by the service IPC contract
// (docs/design/08-windows.md, "IPC").
type Timestamp struct {
	time.Time
}

// NewTimestamp converts t to the timestamp representation used on the wire.
func NewTimestamp(t time.Time) Timestamp {
	return Timestamp{Time: t.UTC()}
}

// MarshalJSON emits a whole-second UTC ISO 8601 timestamp.
func (t Timestamp) MarshalJSON() ([]byte, error) {
	return MarshalWire(t.UTC().Truncate(time.Second).Format(wireTimestampLayout))
}

// UnmarshalJSON accepts RFC 3339 timestamps with offsets and optional fractional seconds.
func (t *Timestamp) UnmarshalJSON(data []byte) error {
	var text string
	if err := json.Unmarshal(data, &text); err != nil {
		return fmt.Errorf("timestamp must be an RFC 3339 string: %w", err)
	}
	parsed, err := time.Parse(time.RFC3339Nano, text)
	if err != nil {
		return fmt.Errorf("invalid RFC 3339 timestamp %q: %w", text, err)
	}
	t.Time = parsed.UTC()
	return nil
}

// marshalWire encodes like json.Marshal but leaves <, > and & alone: the app's decoder
// does not need the HTML escapes and the pinned wire literals are shared with Dart.
func MarshalWire(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buffer.Bytes(), "\n"), nil
}

func decodeWireCase(data []byte, typeName string) (string, json.RawMessage, error) {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil {
		return "", nil, fmt.Errorf("%s must be an object: %w", typeName, err)
	}
	if len(object) != 1 {
		return "", nil, fmt.Errorf("%s must contain exactly one case", typeName)
	}
	for kind, payload := range object {
		var payloadObject map[string]json.RawMessage
		if err := json.Unmarshal(payload, &payloadObject); err != nil || payloadObject == nil {
			if err == nil {
				err = fmt.Errorf("payload is null")
			}
			return "", nil, fmt.Errorf("%s case %q must contain an object payload: %w", typeName, kind, err)
		}
		return kind, payload, nil
	}
	panic("unreachable")
}

func decodeRequiredObject(data []byte, name string, destination any) error {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(data, &object); err != nil {
		return fmt.Errorf("%s must be an object: %w", name, err)
	}
	if object == nil {
		return fmt.Errorf("%s must be an object", name)
	}
	if err := json.Unmarshal(data, destination); err != nil {
		return fmt.Errorf("invalid %s: %w", name, err)
	}
	return nil
}

func nonNilSlice[T any](values []T) []T {
	if values == nil {
		return []T{}
	}
	return values
}

func nonNilMap[K comparable, V any](values map[K]V) map[K]V {
	if values == nil {
		return map[K]V{}
	}
	return values
}

func nonNilStringSlices(values map[string][]string) map[string][]string {
	result := make(map[string][]string, len(values))
	for key, value := range values {
		result[key] = nonNilSlice(value)
	}
	return result
}
