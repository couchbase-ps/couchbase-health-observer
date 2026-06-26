package svchealth

import "testing"

func p(svc, host string, ok bool) Probe { return Probe{Service: svc, Host: host, OK: ok} }

func TestComputeAllUp(t *testing.T) {
	probes := []Probe{p("kv", "d1", true), p("kv", "d2", true), p("query", "q1", true)}
	r := Compute(probes, []string{"kv", "query"}, "2026-06-19T00:00:00Z")
	if r.Status != "UP" {
		t.Fatalf("global = %s, want UP (%s)", r.Status, r.Reason)
	}
	if r.Services["kv"].Status != "UP" || r.Services["kv"].Reachable != 2 {
		t.Errorf("kv rollup wrong: %+v", r.Services["kv"])
	}
}

func TestComputeServiceDownEndpoint(t *testing.T) {
	// one kv endpoint unreachable -> kv DOWN (a vbucket owner is unreachable)
	probes := []Probe{p("kv", "d1", true), p("kv", "d2", false), p("query", "q1", true)}
	r := Compute(probes, []string{"kv"}, "t")
	if r.Services["kv"].Status != "DOWN" {
		t.Fatalf("kv = %s, want DOWN", r.Services["kv"].Status)
	}
	if r.Status != "DOWN" {
		t.Fatalf("global = %s, want DOWN (kv critical)", r.Status)
	}
	if len(r.Services["kv"].Unreachable) != 1 || r.Services["kv"].Unreachable[0] != "d2" {
		t.Errorf("unreachable wrong: %+v", r.Services["kv"].Unreachable)
	}
}

func TestComputeNonCriticalServiceDownDegraded(t *testing.T) {
	// query fully down, app only treats kv as critical -> global DEGRADED (not UP, not DOWN),
	// query DOWN in detail.
	probes := []Probe{p("kv", "d1", true), p("kv", "d2", true), p("query", "q1", false), p("query", "q2", false)}
	r := Compute(probes, []string{"kv"}, "t")
	if r.Status != "DEGRADED" {
		t.Fatalf("global = %s, want DEGRADED (kv up, query down)", r.Status)
	}
	if r.Services["query"].Status != "DOWN" {
		t.Errorf("query should still show DOWN for observability")
	}
	if r.Reason != `non-critical service "query" has 2 non reachable endpoint(s)` {
		t.Errorf("degraded reason wrong: %q", r.Reason)
	}
}

func TestComputeCriticalDownBeatsDegraded(t *testing.T) {
	// Both a critical (kv) and a non-critical (query) service down -> DOWN wins over DEGRADED.
	probes := []Probe{p("kv", "d1", true), p("kv", "d2", false), p("query", "q1", false)}
	r := Compute(probes, []string{"kv"}, "t")
	if r.Status != "DOWN" {
		t.Fatalf("global = %s, want DOWN (kv critical and down)", r.Status)
	}
}

func TestComputeCriticalDownReason(t *testing.T) {
	// Reason must report NON-reachable endpoint count, not reachable count.
	probes := []Probe{p("kv", "d1", true), p("kv", "d2", true), p("kv", "d3", false)}
	r := Compute(probes, []string{"kv"}, "t")
	if r.Reason != `critical service "kv" has 1 non reachable endpoint(s)` {
		t.Errorf("critical down reason wrong: %q", r.Reason)
	}
}

func TestComputeCriticalNotObservedReason(t *testing.T) {
	probes := []Probe{p("query", "q1", true)}
	r := Compute(probes, []string{"kv"}, "t")
	if r.Status != "DOWN" {
		t.Fatalf("global = %s, want DOWN", r.Status)
	}
	if r.Reason != `critical service "kv" not observed` {
		t.Errorf("not-observed reason wrong: %q", r.Reason)
	}
}

func TestComputeOmitsNonDeployedService(t *testing.T) {
	// A service with no deployed node yields a placeholder ping with an empty host;
	// it must NOT appear in the report.
	probes := []Probe{p("kv", "d1", true), p("kv", "d2", true), p("analytics", "", false)}
	r := Compute(probes, []string{"kv"}, "t")
	if _, ok := r.Services["analytics"]; ok {
		t.Errorf("analytics (not deployed) should be omitted, got %+v", r.Services["analytics"])
	}
	if _, ok := r.Services["kv"]; !ok {
		t.Error("kv should be present")
	}
	if r.Status != "UP" {
		t.Fatalf("global = %s, want UP", r.Status)
	}
}

func TestComputeNoProbesDown(t *testing.T) {
	r := Compute(nil, []string{"kv"}, "t")
	if r.Status != "DOWN" {
		t.Fatalf("no probes -> global %s, want DOWN", r.Status)
	}
}
