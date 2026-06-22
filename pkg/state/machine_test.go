package state

import (
	"testing"
	"time"
)

func TestSwitchRequiresSustainedDown(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 30 * time.Second, Now: func() time.Time { return now }})

	m.Observe("UP") // arm: a switch only happens after the cluster was seen healthy
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

func TestSwitchFiresOnce(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 1 * time.Second, Now: func() time.Time { return now }})
	m.Observe("UP")   // arm
	m.Observe("DOWN") // start the timer
	now = now.Add(2 * time.Second)
	if !m.Observe("DOWN").SwitchRequired {
		t.Fatal("expected switch after sustained DOWN")
	}
	now = now.Add(2 * time.Second)
	if m.Observe("DOWN").SwitchRequired {
		t.Fatal("switch must fire once, not repeatedly")
	}
}

func TestNoAutoFailback(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 1 * time.Second, Now: func() time.Time { return now }})
	m.Observe("UP")   // arm
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

// Cold-start guard: if the observer boots into an already-down primary (e.g. a pod
// reschedule during an outage), it must not switch until it has seen the cluster
// healthy at least once. Otherwise a restart mid-outage would auto-fail-over.
func TestNoSwitchUntilFirstHealthy(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 1 * time.Second, Now: func() time.Time { return now }})

	m.Observe("DOWN") // DOWN from the very first observation, never armed
	now = now.Add(10 * time.Second)
	if m.Observe("DOWN").SwitchRequired {
		t.Fatal("switched before ever observing a healthy cluster (cold-start guard)")
	}

	// Once healthy is seen the machine arms; a later sustained DOWN switches.
	m.Observe("UP")
	m.Observe("DOWN")
	now = now.Add(2 * time.Second)
	if !m.Observe("DOWN").SwitchRequired {
		t.Fatal("no switch after arming and sustained DOWN")
	}
}
