package svchealth

import (
	"context"
	"sync/atomic"
)

// ActiveProber points at the cluster that is currently active: the primary
// until a region switch, the secondary after one (failback stays manual). The
// poll loop and the /health/couchbase handler share one instance, so a single
// Set moves both onto the new active cluster instead of leaving them reporting
// the abandoned one.
type ActiveProber struct {
	p atomic.Pointer[Prober]
}

// NewActiveProber starts out probing p (the primary at startup).
func NewActiveProber(p Prober) *ActiveProber {
	a := &ActiveProber{}
	a.Set(p)
	return a
}

// Set makes p the active target for every later Probe. Safe against concurrent
// Probe calls from the HTTP handler.
func (a *ActiveProber) Set(p Prober) { a.p.Store(&p) }

func (a *ActiveProber) Probe(ctx context.Context) ([]Probe, error) {
	return (*a.p.Load()).Probe(ctx)
}
