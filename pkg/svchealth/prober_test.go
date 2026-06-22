package svchealth

import (
	"context"
	"errors"
	"testing"
)

func TestMockProberReturnsCannedProbes(t *testing.T) {
	m := MockProber{Probes: []Probe{{Service: "kv", Host: "d1", OK: true}}}
	got, err := m.Probe(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Service != "kv" || !got[0].OK {
		t.Errorf("got %+v", got)
	}
}

func TestMockProberReturnsErr(t *testing.T) {
	m := MockProber{Err: errors.New("boom")}
	if _, err := m.Probe(context.Background()); err == nil {
		t.Error("expected error")
	}
}
