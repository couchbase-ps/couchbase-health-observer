package svchealth

import (
	"encoding/json"
	"testing"
)

func TestReportJSONShape(t *testing.T) {
	r := Report{
		Status:   "DOWN",
		Critical: []string{"kv", "query"},
		Services: map[string]ServiceHealth{
			"kv":    {Status: "UP", Reachable: 3, Unreachable: []string{}},
			"query": {Status: "DOWN", Reachable: 0, Unreachable: []string{"cb-index-query-1", "cb-index-query-2"}},
		},
		Reason:    "critical service \"query\" has 0 reachable endpoints",
		CheckedAt: "2026-06-19T00:00:00Z",
	}
	b, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	var back map[string]any
	json.Unmarshal(b, &back)
	if back["status"] != "DOWN" {
		t.Errorf("status field = %v", back["status"])
	}
	svcs, ok := back["services"].(map[string]any)
	if !ok || svcs["query"] == nil {
		t.Error("services.query missing in JSON")
	}
}
