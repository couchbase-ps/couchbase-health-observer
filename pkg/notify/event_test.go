package notify

import (
	"context"
	"encoding/json"
	"testing"
)

// The payload is a published contract with Emirates: their pipeline reads these
// exact field names. Assert the marshalled shape, not just the struct.
func TestEventJSONShape(t *testing.T) {
	e := Event{
		Event:          "switch_required",
		SentAt:         "2026-08-19T10:31:02Z",
		Attempt:        1,
		Reason:         `critical service "kv" 3/3 endpoints unreachable`,
		SustainedDownS: 152,
		From:           Endpoint{Role: "primary", Conn: "couchbase://10.0.1.5,10.0.1.6", Label: "10.0.1.5", Nodes: []string{"10.0.1.5", "10.0.1.6"}},
		To:             Endpoint{Role: "secondary", Conn: "couchbase://10.1.1.5", Label: "10.1.1.5", Status: "UP"},
		ConfigMaps:     []string{"urp-dev/cb-conn"},
		Deployments:    []string{"urp-dev/mca-api"},
		Actuators:      []string{"webhook"},
		DryRun:         false,
	}
	raw, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"event", "sent_at", "attempt", "reason", "sustained_down_s", "from", "to", "configmaps", "deployments", "actuators", "dry_run"} {
		if _, ok := got[key]; !ok {
			t.Errorf("payload is missing field %q: %s", key, raw)
		}
	}
	to := got["to"].(map[string]any)
	if to["conn"] != "couchbase://10.1.1.5" {
		t.Errorf("to.conn = %v, want the secondary connstring", to["conn"])
	}
	if to["status"] != "UP" {
		t.Errorf("to.status = %v, want UP", to["status"])
	}
	from := got["from"].(map[string]any)
	if len(from["nodes"].([]any)) != 2 {
		t.Errorf("from.nodes = %v, want both primary hosts", from["nodes"])
	}
}

// TestEventJSONShapeWithEmptyOptional pins the opposite of a contract-key rule:
// configmaps and deployments describe the Kubernetes actuator, so on a
// webhook-only switch they carry nothing to say and are omitted rather than
// sent empty. A receiver must treat both as optional.
func TestEventJSONShapeOmitsEmptyKubernetesFields(t *testing.T) {
	e := Event{
		Event:          "switch_required",
		SentAt:         "2026-08-19T10:31:02Z",
		Attempt:        1,
		Reason:         "test reason",
		SustainedDownS: 10,
		From:           Endpoint{Role: "primary", Conn: "couchbase://10.0.1.5", Label: "10.0.1.5"},
		To:             Endpoint{Role: "secondary", Conn: "couchbase://10.1.1.5", Label: "10.1.1.5"},
		ConfigMaps:     nil,
		Deployments:    nil,
		Actuators:      []string{"webhook"},
		DryRun:         false,
	}
	raw, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"configmaps", "deployments"} {
		if _, ok := got[key]; ok {
			t.Errorf("payload carries an empty %q; a webhook-only switch has no Kubernetes target to report: %s", key, raw)
		}
	}
	// The keys that always mean something must still be there.
	for _, key := range []string{"event", "to", "actuators"} {
		if _, ok := got[key]; !ok {
			t.Errorf("payload is missing required field %q: %s", key, raw)
		}
	}
}

func TestMockRecordsCalls(t *testing.T) {
	var n Notifier = &Mock{}
	if err := n.Notify(context.Background(), Event{Event: "switch_required"}); err != nil {
		t.Fatal(err)
	}
	m := n.(*Mock)
	if len(m.Calls) != 1 || m.Calls[0].Event != "switch_required" {
		t.Fatalf("mock recorded %+v, want one switch_required call", m.Calls)
	}
}
