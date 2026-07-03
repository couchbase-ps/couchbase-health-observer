// Package metrics is the observer's self-observability surface: series about the
// observer and its verdicts (not just the database), served at /metrics for
// Prometheus. Uses a dedicated registry so tests are deterministic.
package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var reg = prometheus.NewRegistry()

func gauge(name, help string) prometheus.Gauge {
	g := prometheus.NewGauge(prometheus.GaugeOpts{Name: name, Help: help})
	reg.MustRegister(g)
	return g
}

func gaugeVec(name, help string, labels ...string) *prometheus.GaugeVec {
	g := prometheus.NewGaugeVec(prometheus.GaugeOpts{Name: name, Help: help}, labels)
	reg.MustRegister(g)
	return g
}

func counter(name, help string) prometheus.Counter {
	c := prometheus.NewCounter(prometheus.CounterOpts{Name: name, Help: help})
	reg.MustRegister(c)
	return c
}

var (
	LoopLastTick = gauge("observer_loop_last_tick_timestamp_seconds",
		"Unix time of the last active-loop iteration (heartbeat age source).")
	CouchbaseUp = gaugeVec("observer_couchbase_up",
		"Current DB verdict per region (1=UP, 0=DOWN).", "region")
	ServiceUp = gaugeVec("observer_service_up",
		"Per-service ping result (1=reachable, 0=not).", "service")
	SustainedDownSeconds = gauge("observer_sustained_down_seconds",
		"How long the current primary outage has persisted (0 when healthy).")
	ActiveRegion = gaugeVec("observer_active_region",
		"Region the app ConfigMap currently points to (value 1 on the active label).", "region")
	FailoverTotal = counter("observer_failover_total",
		"Total successful region switches performed.")
	FailoverErrors = counter("observer_failover_errors_total",
		"Total actuation errors.")
	LastActuationSuccess = gauge("observer_last_actuation_success_timestamp_seconds",
		"Unix time of the last successful actuation.")
	SecondaryUp = gauge("observer_secondary_up",
		"Secondary region readiness at last check (1=UP, 0=not; switch is held when 0).")
)

// Handler serves the observer's metrics registry.
func Handler() http.Handler {
	return promhttp.HandlerFor(reg, promhttp.HandlerOpts{})
}
