package svchealth

import "testing"

func TestByNode(t *testing.T) {
	probes := []Probe{
		p("kv", "d2", true), p("query", "d2", true),
		p("kv", "d1", false),
		p("analytics", "", false), // placeholder, dropped
	}
	nodes := ByNode(probes)
	if len(nodes) != 2 {
		t.Fatalf("want 2 nodes, got %d: %+v", len(nodes), nodes)
	}
	if nodes[0].Host != "d1" || len(nodes[0].Unreachable) != 1 || nodes[0].Unreachable[0] != "kv" {
		t.Errorf("d1 wrong: %+v", nodes[0])
	}
	if nodes[1].Host != "d2" || len(nodes[1].Reachable) != 2 {
		t.Errorf("d2 wrong: %+v", nodes[1])
	}
}

func TestNodeSummary(t *testing.T) {
	nodes := ByNode([]Probe{p("kv", "d1", true), p("kv", "d2", false), p("kv", "d3", true)})
	healthy, total := NodeSummary(nodes)
	if healthy != 2 || total != 3 {
		t.Errorf("summary = %d/%d, want 2/3", healthy, total)
	}
}

func TestRenderNodes(t *testing.T) {
	nodes := ByNode([]Probe{p("kv", "d1", true), p("query", "d1", true), p("kv", "d2", false)})
	got := RenderNodes(nodes)
	want := "d1 UP(kv query), d2 DOWN(kv)"
	if got != want {
		t.Errorf("render = %q, want %q", got, want)
	}
}

func TestHostSetAndDiff(t *testing.T) {
	prev := HostSet([]Probe{p("kv", "d1", true), p("kv", "d2", true), p("kv", "", false)})
	cur := HostSet([]Probe{p("kv", "d2", true), p("kv", "d3", true)})
	if _, ok := prev[""]; ok {
		t.Error("empty host must not be in the set")
	}
	added, removed := DiffHosts(prev, cur)
	if len(added) != 1 || added[0] != "d3" {
		t.Errorf("added = %v, want [d3]", added)
	}
	if len(removed) != 1 || removed[0] != "d1" {
		t.Errorf("removed = %v, want [d1]", removed)
	}
}
