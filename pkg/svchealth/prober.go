package svchealth

import "context"

// Probe is one endpoint's reachability for one service on one node.
type Probe struct {
	Service string // kv | query | search | analytics | management
	Host    string // node host (no port)
	OK      bool   // ping state == Ok
}

// Prober returns the current per-endpoint reachability across services.
type Prober interface {
	Probe(ctx context.Context) ([]Probe, error)
}

// MockProber returns a canned set for tests.
type MockProber struct {
	Probes []Probe
	Err    error
}

func (m MockProber) Probe(context.Context) ([]Probe, error) { return m.Probes, m.Err }
