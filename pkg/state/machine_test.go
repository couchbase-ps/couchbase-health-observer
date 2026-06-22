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

func TestSwitchFiresOnce(t *testing.T) {
	now := time.Unix(0, 0)
	m := New(Config{FailoverDelay: 1 * time.Second, Now: func() time.Time { return now }})
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
