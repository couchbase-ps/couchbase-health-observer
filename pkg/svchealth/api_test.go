package svchealth

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHandlerDownReturns503(t *testing.T) {
	pr := MockProber{Probes: []Probe{p("kv", "d1", true), p("kv", "d2", false)}}
	h := &Handler{Prober: pr, Critical: []string{"kv"}, Now: func() string { return "t" }}
	req := httptest.NewRequest("GET", "/health/couchbase", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", w.Code)
	}
	var r Report
	json.Unmarshal(w.Body.Bytes(), &r)
	if r.Status != "DOWN" || r.Services["kv"].Status != "DOWN" {
		t.Errorf("body = %+v", r)
	}
}

func TestHandlerUpReturns200(t *testing.T) {
	pr := MockProber{Probes: []Probe{p("kv", "d1", true), p("query", "q1", false)}}
	h := &Handler{Prober: pr, Critical: []string{"kv"}, Now: func() string { return "t" }}
	req := httptest.NewRequest("GET", "/health/couchbase", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (kv up, query not critical)", w.Code)
	}
}
