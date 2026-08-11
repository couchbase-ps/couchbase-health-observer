package state

import (
	"testing"
	"time"
)

func TestSwitchRequiresSustainedDown(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 30 * time.Second, Now: func() time.Time { return now }})

	if m.Observe("DOWN").SwitchRequired {
		t.Fatal("switch on first DOWN, want false")
	}
	now = now.Add(20 * time.Second)
	if m.Observe("DOWN").SwitchRequired {
		t.Fatal("switch before FailoverDelay elapsed")
	}
	now = now.Add(15 * time.Second) // total 35s > 30s
	if !m.Observe("DOWN").SwitchRequired {
		t.Fatal("no switch after sustained DOWN past FailoverDelay")
	}
}

func TestHealthyResetsDownTimer(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 30 * time.Second, Now: func() time.Time { return now }})
	m.Observe("DOWN")
	now = now.Add(20 * time.Second)
	m.Observe("UP") // recovered before delay -> reset
	now = now.Add(20 * time.Second)
	if m.Observe("DOWN").SwitchRequired {
		t.Fatal("DOWN timer not reset after healthy")
	}
}

func TestSwitchRequiredRepeatsUntilMarked(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 1 * time.Second, Now: func() time.Time { return now }})
	m.Observe("DOWN") // start the timer
	now = now.Add(2 * time.Second)
	if !m.Observe("DOWN").SwitchRequired {
		t.Fatal("expected switch after sustained DOWN")
	}
	// Actuation NOT yet confirmed (e.g. the secondary was not ready and the switch
	// was held): the machine must KEEP requesting the switch so it retries once
	// the secondary recovers, instead of stranding the observer on a dead primary.
	now = now.Add(2 * time.Second)
	if !m.Observe("DOWN").SwitchRequired {
		t.Fatal("switch must keep being requested until MarkSwitched (held-switch retry)")
	}
	// Actuation succeeded -> the loop marks it; no further switches are requested.
	m.MarkSwitched()
	now = now.Add(2 * time.Second)
	if m.Observe("DOWN").SwitchRequired {
		t.Fatal("switch must not be requested again once actuation is confirmed")
	}
}

func TestNoAutoFailback(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 1 * time.Second, Now: func() time.Time { return now }})
	m.Observe("DOWN") // start the timer
	now = now.Add(2 * time.Second)
	if !m.Observe("DOWN").SwitchRequired { // switches
		t.Fatal("expected switch")
	}
	now = now.Add(60 * time.Second)
	if m.Observe("UP").FailbackRequired {
		t.Fatal("auto-failback must never be required")
	}
}

// Cold start into an already-down primary: the machine must switch after the
// delay even though it never observed the cluster healthy first. The in-memory
// "armed" gate is gone; the ConfigMap seed (Task 2) handles already-switched.
func TestSwitchesOnColdStartDown(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 30 * time.Second, Now: func() time.Time { return now }})

	if m.Observe("DOWN").SwitchRequired { // DOWN from the very first observation
		t.Fatal("switch on first DOWN, want false")
	}
	now = now.Add(35 * time.Second) // sustained past FailoverDelay
	if !m.Observe("DOWN").SwitchRequired {
		t.Fatal("no switch after sustained cold-start DOWN past FailoverDelay")
	}
}

// Seeded AlreadySwitched (ConfigMap already on secondary at startup): a prior
// instance switched, so this machine must never fire again nor roll apps.
func TestAlreadySwitchedSeedNeverFires(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 1 * time.Second, AlreadySwitched: true, Now: func() time.Time { return now }})

	m.Observe("DOWN")
	now = now.Add(60 * time.Second)
	if m.Observe("DOWN").SwitchRequired {
		t.Fatal("seeded already-switched machine must never fire")
	}
}

func TestMachineSwitchedFlag(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 10 * time.Second, Now: func() time.Time { return now }})
	if m.Switched() {
		t.Fatal("fresh machine should not be switched")
	}
	m.Observe("DOWN") // starts the clock
	now = now.Add(11 * time.Second)
	if r := m.Observe("DOWN"); !r.SwitchRequired {
		t.Fatal("switch should be required after the delay")
	}
	if m.Switched() {
		t.Error("must NOT report switched before actuation is confirmed (only the decision was made)")
	}
	m.MarkSwitched()
	if !m.Switched() {
		t.Error("Switched() should be true after MarkSwitched")
	}
}

func TestMachineSwitchedSeed(t *testing.T) {
	if !New(Config{AlreadySwitched: true}).Switched() {
		t.Error("AlreadySwitched should seed Switched()=true")
	}
}
