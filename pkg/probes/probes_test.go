package probes

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func fixedClock(t time.Time) func() time.Time { return func() time.Time { return t } }

func TestLivenessFreshReturns200(t *testing.T) {
	now := time.Unix(1000, 0)
	hb := &Heartbeat{}
	hb.tickAt(now)
	h := Liveness(hb, 15*time.Second, fixedClock(now.Add(5*time.Second)))
	w := httptest.NewRecorder()
	h(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("code=%d, want 200 (tick 5s old < 15s max)", w.Code)
	}
}

func TestLivenessStaleReturns503(t *testing.T) {
	now := time.Unix(1000, 0)
	hb := &Heartbeat{}
	hb.tickAt(now)
	h := Liveness(hb, 15*time.Second, fixedClock(now.Add(20*time.Second)))
	w := httptest.NewRecorder()
	h(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("code=%d, want 503 (tick 20s old > 15s max)", w.Code)
	}
}

func TestLivenessNeverTickedReturns200(t *testing.T) {
	hb := &Heartbeat{}
	h := Liveness(hb, 15*time.Second, fixedClock(time.Unix(1000, 0)))
	w := httptest.NewRecorder()
	h(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("code=%d, want 200 (never ticked = startup grace)", w.Code)
	}
}

func TestLivenessObserveModeStatic200(t *testing.T) {
	h := Liveness(nil, 15*time.Second, fixedClock(time.Unix(1000, 0)))
	w := httptest.NewRecorder()
	h(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("code=%d, want 200 (observe mode, nil heartbeat)", w.Code)
	}
}

func TestReadinessOKWhenCheckPasses(t *testing.T) {
	h := Readiness(func(context.Context) error { return nil })
	w := httptest.NewRecorder()
	h(w, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("code=%d, want 200", w.Code)
	}
}

func TestReadiness503WhenCheckFails(t *testing.T) {
	h := Readiness(func(context.Context) error { return errNotReady })
	w := httptest.NewRecorder()
	h(w, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("code=%d, want 503", w.Code)
	}
}

type stubErr string

func (e stubErr) Error() string { return string(e) }

var errNotReady = stubErr("k8s API unreachable")
