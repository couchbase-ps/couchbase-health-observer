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

func TestComputeNonCriticalServiceDownStaysUp(t *testing.T) {
	// query fully down, but app only treats kv as critical -> global UP, query DOWN in detail
	probes := []Probe{p("kv", "d1", true), p("kv", "d2", true), p("query", "q1", false), p("query", "q2", false)}
	r := Compute(probes, []string{"kv"}, "t")
	if r.Status != "UP" {
		t.Fatalf("global = %s, want UP (query not critical)", r.Status)
	}
	if r.Services["query"].Status != "DOWN" {
		t.Errorf("query should still show DOWN for observability")
	}
}

func TestComputeNoProbesDown(t *testing.T) {
	r := Compute(nil, []string{"kv"}, "t")
	if r.Status != "DOWN" {
		t.Fatalf("no probes -> global %s, want DOWN", r.Status)
	}
}
