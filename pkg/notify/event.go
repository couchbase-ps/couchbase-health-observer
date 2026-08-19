// Package notify delivers the observer's switch request to an external HTTP
// endpoint, so an operator can drive the switch from their own pipeline instead
// of (or as well as) the in-observer Kubernetes actuator. Whether a failed
// delivery may latch the switch depends on what else is enabled: alone, it is
// the actuator and a failure must not latch; alongside the Kubernetes
// actuator, it is a notification and a failure does not block the latch (see
// cmd/svchealthcheck/switch.go runSwitch).
package notify

import "context"

// Endpoint describes one side of the switch in the payload.
type Endpoint struct {
	Role   string   `json:"role"`             // "primary" | "secondary"
	Conn   string   `json:"conn"`             // full connection string
	Label  string   `json:"label"`            // short cluster label used in logs
	Nodes  []string `json:"nodes,omitempty"`  // hosts currently in the cluster map
	Status string   `json:"status,omitempty"` // last computed status, secondary only
}

// Event is the JSON body POSTed to the webhook. It is declarative: it states the
// target the applications should point at, and the receiver is expected to do
// nothing when they already point there. The observer sends no dedup key and
// keeps no delivery state, so a restart re-sends the same request.
type Event struct {
	Event          string   `json:"event"` // always "switch_required" today
	SentAt         string   `json:"sent_at"`
	Attempt        int      `json:"attempt"`
	Reason         string   `json:"reason"`
	SustainedDownS float64  `json:"sustained_down_s"`
	From           Endpoint `json:"from"`
	To             Endpoint `json:"to"`
	// ConfigMaps and Deployments name the Kubernetes actuator's targets, each
	// entry namespace-qualified as "ns/name" (the observer patches several
	// namespaces in one switch, so there is no single namespace to report).
	// Both are k8s-actuator only and absent on a webhook-only switch.
	ConfigMaps  []string `json:"configmaps,omitempty"`
	Deployments []string `json:"deployments,omitempty"`
	Actuators   []string `json:"actuators"`
	DryRun      bool     `json:"dry_run"`
}

// Notifier delivers one switch request. A non-nil error blocks the switch
// latch only when this notifier is the sole actuator; when the Kubernetes
// actuator is also enabled it decides the latch alone and a Notify error is
// logged but does not hold it open (cmd/svchealthcheck/switch.go runSwitch).
type Notifier interface {
	Notify(ctx context.Context, e Event) error
}

// Mock records calls for tests, mirroring actuator.Mock.
type Mock struct {
	Calls []Event
	Err   error
}

func (m *Mock) Notify(_ context.Context, e Event) error {
	m.Calls = append(m.Calls, e)
	return m.Err
}
