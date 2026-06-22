package svchealth

import (
	"encoding/json"
	"net/http"
	"time"
)

// Handler serves the detailed health JSON. 503 when global is DOWN, else 200.
type Handler struct {
	Prober   Prober
	Critical []string
	Now      func() string // injectable timestamp; defaults to RFC3339 now
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	now := h.Now
	if now == nil {
		now = func() string { return time.Now().UTC().Format(time.RFC3339) }
	}
	probes, err := h.Prober.Probe(r.Context())
	if err != nil {
		probes = nil // treat probe failure as nothing reachable -> DOWN
	}
	report := Compute(probes, h.Critical, now())

	w.Header().Set("Content-Type", "application/json")
	if report.Status == "DOWN" {
		w.WriteHeader(http.StatusServiceUnavailable)
	} else {
		w.WriteHeader(http.StatusOK)
	}
	_ = json.NewEncoder(w).Encode(report)
}
