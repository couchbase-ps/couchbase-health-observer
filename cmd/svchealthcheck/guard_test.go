package main

import "testing"

func TestSecondaryGuard(t *testing.T) {
	if secondaryReady("DOWN") {
		t.Fatal("guard allowed switch into a DOWN secondary")
	}
	if !secondaryReady("UP") {
		t.Fatal("guard blocked switch into a healthy secondary")
	}
	if !secondaryReady("DEGRADED") {
		t.Fatal("DEGRADED secondary should still accept the switch (critical services up)")
	}
}
