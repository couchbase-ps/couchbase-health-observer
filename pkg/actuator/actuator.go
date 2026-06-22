// Package actuator performs the region switch on Kubernetes: repoint the
// connection-string ConfigMap to the secondary cluster and roll the dependent
// Deployments so their pods re-bootstrap. Failover only; failback is manual.
package actuator

import "context"

type Config struct {
	Namespace   string
	ConfigMap   string
	ConfigKey   string
	Deployments []string
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
