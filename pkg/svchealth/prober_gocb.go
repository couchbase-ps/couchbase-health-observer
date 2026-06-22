package svchealth

import (
	"context"

	"github.com/couchbase/gocb/v2"
)

// GocbProber pings the cluster's services and maps each endpoint to a Probe.
// KV ping requires a bucket; cluster-level services (query/search/analytics/mgmt)
// are pinged at the cluster level.
type GocbProber struct {
	Cluster *gocb.Cluster
	Bucket  *gocb.Bucket // for KV ping
}

func (g *GocbProber) Probe(_ context.Context) ([]Probe, error) {
	var probes []Probe

	// KV via the bucket.
	if g.Bucket != nil {
		if pr, err := g.Bucket.Ping(&gocb.PingOptions{ServiceTypes: []gocb.ServiceType{gocb.ServiceTypeKeyValue}}); err == nil {
			probes = append(probes, mapReports(pr)...)
		}
	}
	// Cluster-level data-serving services. Management (8091) is intentionally excluded:
	// it is present on every node and is not a workload service. Services with no
	// deployed node yield placeholder (empty-host) reports, which Compute drops.
	if pr, err := g.Cluster.Ping(&gocb.PingOptions{ServiceTypes: []gocb.ServiceType{
		gocb.ServiceTypeQuery, gocb.ServiceTypeSearch, gocb.ServiceTypeAnalytics,
	}}); err == nil {
		probes = append(probes, mapReports(pr)...)
	}
	return probes, nil
}

func mapReports(pr *gocb.PingResult) []Probe {
	var out []Probe
	for svc, reports := range pr.Services {
		name := serviceName(svc)
		for _, r := range reports {
			out = append(out, Probe{Service: name, Host: hostOnly(r.Remote), OK: r.State == gocb.PingStateOk})
		}
	}
	return out
}

func serviceName(s gocb.ServiceType) string {
	switch s {
	case gocb.ServiceTypeKeyValue:
		return "kv"
	case gocb.ServiceTypeQuery:
		return "query"
	case gocb.ServiceTypeSearch:
		return "search"
	case gocb.ServiceTypeAnalytics:
		return "analytics"
	case gocb.ServiceTypeManagement:
		return "management"
	default:
		return "other"
	}
}

func hostOnly(hostport string) string {
	for i := len(hostport) - 1; i >= 0; i-- {
		if hostport[i] == ':' {
			return hostport[:i]
		}
	}
	return hostport
}
