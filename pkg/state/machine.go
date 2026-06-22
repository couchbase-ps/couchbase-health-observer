// Package state turns a stream of point-in-time global health verdicts into a
// stable switch decision. It applies FailoverDelay so a transient or
// soon-absorbed DOWN does not trigger a region switch; only DOWN sustained past
// the delay does. Failback is never automatic.
package state

import "time"

type Config struct {
	FailoverDelay time.Duration
	Now           func() time.Time // injectable clock; defaults to time.Now
}

type Machine struct {
	cfg         Config
	firstDownAt time.Time
	inDown      bool
	switched    bool
}

type Result struct {
	Status           string
	SwitchRequired   bool
	FailbackRequired bool // always false: failback is operator-driven, kept for clarity
}

func New(cfg Config) *Machine {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	return &Machine{cfg: cfg}
}

// Observe records the latest global status ("UP"/"DOWN"; anything other than
// "DOWN" is treated as healthy) and reports whether a region switch is now due.
func (m *Machine) Observe(status string) Result {
	now := m.cfg.Now()
	res := Result{Status: status}

	if status != "DOWN" {
		// healthy (UP/DEGRADED): reset the DOWN timer. Do not auto-failback even
		// if previously switched.
		m.inDown = false
		return res
	}

	if !m.inDown {
		m.inDown = true
		m.firstDownAt = now
	}
	if !m.switched && now.Sub(m.firstDownAt) >= m.cfg.FailoverDelay {
		res.SwitchRequired = true
		m.switched = true
	}
	return res
}
