package metrics

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSeriesRegisteredAndSettable(t *testing.T) {
	CouchbaseUp.WithLabelValues("region-a").Set(1)
	ServiceUp.WithLabelValues("kv").Set(1)
	SustainedDownSeconds.Set(0)
	SecondaryUp.Set(1)
	ActiveRegion.WithLabelValues("region-a").Set(1)
	FailoverTotal.Add(0)

	for _, name := range []string{
		"observer_couchbase_up", "observer_service_up", "observer_sustained_down_seconds",
		"observer_secondary_up", "observer_active_region", "observer_failover_total",
	} {
		if !exposed(t, name) {
			t.Errorf("series %q not exposed", name)
		}
	}
}

func TestWebhookMetricsExposed(t *testing.T) {
	WebhookTotal.WithLabelValues("ok").Inc()
	WebhookTotal.WithLabelValues("error").Inc()
	WebhookLastSuccess.Set(1755600000)

	rec := httptest.NewRecorder()
	Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/metrics", nil))
	body := rec.Body.String()
	for _, want := range []string{
		`observer_webhook_total{result="ok"} 1`,
		`observer_webhook_total{result="error"} 1`,
		"observer_webhook_last_success_timestamp_seconds 1.7556e+09",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics is missing %q\n%s", want, body)
		}
	}
}

func exposed(t *testing.T, name string) bool {
	t.Helper()
	mfs, err := reg.Gather()
	if err != nil {
		t.Fatal(err)
	}
	for _, mf := range mfs {
		if mf.GetName() == name {
			return true
		}
	}
	return false
}
