package main

import (
	"fmt"
	"strings"
)

// Actuators is the set of actions the observer performs on a switch decision.
// The zero value performs none, which is observe-only mode: the health endpoint
// is served and no poll loop runs. Because the flag value IS the set, "active
// but nothing configured" cannot be expressed.
type Actuators struct {
	K8s     bool // patch the connstring ConfigMap and roll the dependent Deployments
	Webhook bool // POST the switch request to an external endpoint
}

// Any reports whether at least one actuator is enabled (i.e. run the loop).
func (a Actuators) Any() bool { return a.K8s || a.Webhook }

// List renders the enabled actuators in a stable order, for logs and payloads.
func (a Actuators) List() []string {
	var out []string
	if a.K8s {
		out = append(out, "k8s")
	}
	if a.Webhook {
		out = append(out, "webhook")
	}
	return out
}

// parseActuators turns --actuators (and the deprecated --mode) into the set.
// A non-empty list always wins; --mode is only consulted when the list is empty.
// The second return value reports that --mode was supplied at all, so the caller
// can emit the deprecation warning. --mode is removed one release from now.
func parseActuators(list, mode string) (Actuators, bool, error) {
	deprecated := mode != ""
	if list != "" {
		var a Actuators
		for _, part := range strings.Split(list, ",") {
			switch strings.TrimSpace(part) {
			case "":
				continue
			case "k8s":
				a.K8s = true
			case "webhook":
				a.Webhook = true
			default:
				return Actuators{}, false, fmt.Errorf("unknown actuator %q in --actuators (want k8s and/or webhook)", strings.TrimSpace(part))
			}
		}
		return a, deprecated, nil
	}
	switch mode {
	case "", "observe":
		return Actuators{}, deprecated, nil
	case "active":
		return Actuators{K8s: true}, deprecated, nil
	default:
		return Actuators{}, false, fmt.Errorf("unknown --mode %q (want observe or active; --mode is deprecated, use --actuators)", mode)
	}
}
