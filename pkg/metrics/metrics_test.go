package metrics

import "testing"

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
