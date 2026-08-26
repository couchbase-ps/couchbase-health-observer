package svchealth

import (
	"context"
	"errors"
	"sync"
	"testing"
)

// The observer must probe whichever cluster is currently active: the primary
// until a region switch, the secondary after it. Both the poll loop and the
// /health/couchbase handler read the same holder, so one Set switches both.
func TestActiveProberSetSwapsTarget(t *testing.T) {
	primary := MockProber{Probes: []Probe{{Service: "kv", Host: "10.0.0.1", OK: true}}}
	secondary := MockProber{Probes: []Probe{{Service: "kv", Host: "10.1.0.1", OK: true}}}

	ap := NewActiveProber(primary)
	got, err := ap.Probe(context.Background())
	if err != nil {
		t.Fatalf("probe primary: %v", err)
	}
	if len(got) != 1 || got[0].Host != "10.0.0.1" {
		t.Fatalf("before Set: probed %v, want the primary host", got)
	}

	ap.Set(secondary)
	got, err = ap.Probe(context.Background())
	if err != nil {
		t.Fatalf("probe secondary: %v", err)
	}
	if len(got) != 1 || got[0].Host != "10.1.0.1" {
		t.Fatalf("after Set: probed %v, want the secondary host", got)
	}
}

func TestActiveProberPropagatesError(t *testing.T) {
	want := errors.New("unreachable")
	ap := NewActiveProber(MockProber{Err: want})
	if _, err := ap.Probe(context.Background()); !errors.Is(err, want) {
		t.Fatalf("Probe err = %v, want %v", err, want)
	}
}

// The handler goroutine reads while the loop swaps: must be race-free.
func TestActiveProberConcurrentSetAndProbe(t *testing.T) {
	ap := NewActiveProber(MockProber{Probes: []Probe{{Service: "kv", Host: "a", OK: true}}})
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); ap.Set(MockProber{Probes: []Probe{{Service: "kv", Host: "b", OK: true}}}) }()
		go func() { defer wg.Done(); _, _ = ap.Probe(context.Background()) }()
	}
	wg.Wait()
}
