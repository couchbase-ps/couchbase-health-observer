// Package actuator performs the region switch on Kubernetes: repoint the
// connection-string ConfigMap to the secondary cluster and roll the dependent
// Deployments so their pods re-bootstrap. Failover only; failback is manual.
package actuator

import "context"

// Annotation names stamped on a rolled Deployment. AnnSwitchedTo is deterministic
// (the secondary connstring), so a retry can tell an already-rolled Deployment from
// one still to roll. AnnRestartedAt is informational.
const (
	AnnSwitchedTo  = "observer/switched-to"
	AnnRestartedAt = "observer/restartedAt"
)

type Config struct {
	ConfigMaps  []Ref // connstring ConfigMaps to patch, each with its own namespace
	ConfigKey   string
	Deployments []Ref  // Deployments to roll, each with its own namespace
	Secondary   string // connection string to switch to
	DryRun      bool
}

// Actuator performs a region switch. Returns switched=false when it was a no-op
// (already on secondary) so the caller can log idempotent skips.
type Actuator interface {
	Switch(ctx context.Context) (switched bool, err error)
}

// Mock records the call for tests.
type Mock struct {
	Called   bool
	Switched bool
	Err      error
}

func (m *Mock) Switch(context.Context) (bool, error) {
	m.Called = true
	return m.Switched, m.Err
}
