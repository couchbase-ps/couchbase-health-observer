// Package probes serves the observer's process-self health signals, kept
// strictly separate from database health (/health/couchbase):
//
//	/healthz (liveness)  - is the active loop alive? Fails ONLY for a restart-fixable
//	                       condition (a frozen/stalled loop). Wired to the kubelet
//	                       livenessProbe. NEVER wire liveness to /health/couchbase.
//	/readyz  (readiness) - is the observer configured and wired to act (K8s API
//	                       reachable)? Fails non-destructively; kubelet marks the pod
//	                       NOT READY but never restarts it.
package probes

import (
	"context"
	"net/http"
	"sync/atomic"
	"time"
)

// Heartbeat records the wall-clock time of the last active-loop iteration.
// A stale heartbeat means the loop is stalled/deadlocked (restart-fixable).
type Heartbeat struct {
	lastUnixNano atomic.Int64
}

// Tick stamps the current time. Call once per loop iteration.
func (h *Heartbeat) Tick() { h.lastUnixNano.Store(time.Now().UnixNano()) }

// tickAt stamps an explicit time (test seam).
func (h *Heartbeat) tickAt(t time.Time) { h.lastUnixNano.Store(t.UnixNano()) }

// ticked reports whether Tick has ever been called.
func (h *Heartbeat) ticked() bool { return h.lastUnixNano.Load() != 0 }

// age returns how long ago the last tick was, relative to now.
func (h *Heartbeat) age(now time.Time) time.Duration {
	return now.Sub(time.Unix(0, h.lastUnixNano.Load()))
}

// Liveness returns a handler that is 200 while the loop is alive and 503 when
// it has stalled past maxAge. A nil heartbeat (observe-only mode, no loop) is a
// static 200. Before the first tick (startup grace), it is 200.
func Liveness(hb *Heartbeat, maxAge time.Duration, now func() time.Time) http.HandlerFunc {
	if now == nil {
		now = time.Now
	}
	return func(w http.ResponseWriter, _ *http.Request) {
		if hb == nil || !hb.ticked() {
			w.WriteHeader(http.StatusOK)
			return
		}
		if hb.age(now()) > maxAge {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}

// ReadyFunc reports observer readiness; a non-nil error means NOT READY (503).
type ReadyFunc func(ctx context.Context) error

// Readiness returns a handler that is 200 when check returns nil, else 503 with
// the error text. Re-evaluated on every probe, so a later dependency loss flips it.
func Readiness(check ReadyFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := check(r.Context()); err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}
