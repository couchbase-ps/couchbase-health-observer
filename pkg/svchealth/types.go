// Package svchealth detects Couchbase health from SDK ping() reachability only,
// reporting per-service UP/DOWN and a global status driven by which services the
// application declares critical. No management REST, no membership.
package svchealth

// ServiceHealth is the rollup for one service type.
type ServiceHealth struct {
	Status      string   `json:"status"`      // UP | DOWN
	Reachable   int      `json:"reachable"`   // count of OK endpoints
	Unreachable []string `json:"unreachable"` // hosts with a failing endpoint
}

// Report is the detailed health document served at /health/couchbase.
type Report struct {
	Status    string                   `json:"status"`   // global: DOWN if any critical service DOWN, else UP
	Critical  []string                 `json:"critical"` // configured critical services
	Services  map[string]ServiceHealth `json:"services"` // every probed service
	Reason    string                   `json:"reason"`
	CheckedAt string                   `json:"checkedAt"` // RFC3339
}
