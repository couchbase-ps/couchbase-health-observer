package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"

	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/notify"
)

// TestNewSwitchEventGatesKubernetesFields is the regression test for the
// configmaps/deployments leak: the inline notify.Event{} literal that used to
// live in main() always populated the Kubernetes target fields, regardless of
// whether the k8s actuator was even enabled. Every shipped manifest sets
// --configmap and --deployments explicitly, so a webhook-only switch emitted
// them even though pkg/notify's contract promises they are absent without a
// Kubernetes target. omitempty on the struct tag cannot catch this:
// ["default/cb-conn"] and ["default/mock-app"] are not empty values.
// newSwitchEvent must gate on acts.K8s explicitly instead.
func TestNewSwitchEventGatesKubernetesFields(t *testing.T) {
	from := notify.Endpoint{Role: "primary", Conn: "couchbase://10.0.1.5", Label: "region-a"}
	to := notify.Endpoint{Role: "secondary", Conn: "couchbase://10.1.1.5", Label: "region-b", Status: "UP"}
	cmRefs := []actuator.Ref{{Namespace: "default", Name: "cb-conn"}}
	depRefs := []actuator.Ref{{Namespace: "default", Name: "mock-app"}}

	cases := []struct {
		name        string
		acts        Actuators
		wantPresent bool
	}{
		{"webhook only: configmaps/deployments absent", Actuators{Webhook: true}, false},
		{"k8s enabled: configmaps/deployments present", Actuators{K8s: true}, true},
		{"both enabled: configmaps/deployments present", Actuators{K8s: true, Webhook: true}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Non-empty refs on purpose: they are exactly what every shipped
			// manifest passes, and they are what omitempty fails to drop.
			ev := newSwitchEvent(tc.acts, "critical service down", 152, from, to, cmRefs, depRefs, false)

			raw, err := json.Marshal(ev)
			if err != nil {
				t.Fatal(err)
			}
			var got map[string]any
			if err := json.Unmarshal(raw, &got); err != nil {
				t.Fatal(err)
			}
			_, hasCM := got["configmaps"]
			_, hasDep := got["deployments"]
			if hasCM != tc.wantPresent || hasDep != tc.wantPresent {
				t.Errorf("acts=%+v: configmaps present=%v deployments present=%v, want both %v: %s",
					tc.acts, hasCM, hasDep, tc.wantPresent, raw)
			}
			if tc.wantPresent {
				// Namespace-qualified, so a receiver can act per app namespace.
				cm, _ := got["configmaps"].([]any)
				if len(cm) != 1 || cm[0] != "default/cb-conn" {
					t.Errorf("configmaps = %v, want [default/cb-conn]", got["configmaps"])
				}
				dep, _ := got["deployments"].([]any)
				if len(dep) != 1 || dep[0] != "default/mock-app" {
					t.Errorf("deployments = %v, want [default/mock-app]", got["deployments"])
				}
			}
			// Everything else is always populated exactly as passed in, regardless
			// of the actuator set.
			if got["event"] != "switch_required" {
				t.Errorf("event = %v, want switch_required", got["event"])
			}
			if got["reason"] != "critical service down" {
				t.Errorf("reason = %v", got["reason"])
			}
			if got["sustained_down_s"] != 152.0 {
				t.Errorf("sustained_down_s = %v, want 152", got["sustained_down_s"])
			}
			toGot := got["to"].(map[string]any)
			if toGot["status"] != "UP" {
				t.Errorf("to.status = %v, want UP", toGot["status"])
			}
		})
	}
}

func TestRunSwitchLatching(t *testing.T) {
	info := switchInfo{FromDisp: "primary (10.0.1.5)", ToDisp: "secondary (10.1.1.5)", SecondaryConn: "couchbase://10.1.1.5", PrimaryNodes: "10.0.1.5"}
	cases := []struct {
		name        string
		act         *actuator.Mock // nil -> k8s disabled
		note        *notify.Mock   // nil -> webhook disabled
		wantLatched bool
		wantCalled  bool // actuator called
		wantNotify  int  // webhook deliveries
		// wantDropped asserts whether runSwitch logs webhook_dropped: it must fire
		// only when the webhook failed AND the k8s path actually moved the
		// applications (switched or the already-on-secondary no-op): the same
		// condition that leaves the latch true. A tick where nothing moved must
		// stay silent about it: the existing webhook_failed + actuation_error
		// lines already tell the truth, and claiming a switch happened would not.
		wantDropped bool
	}{
		{"k8s only, switch performed", &actuator.Mock{Switched: true}, nil, true, true, 0, false},
		{"k8s only, already on secondary latches", &actuator.Mock{Switched: false}, nil, true, true, 0, false},
		{"k8s only, error does not latch", &actuator.Mock{Err: errors.New("configmap boom")}, nil, false, true, 0, false},
		{"webhook only, delivered", nil, &notify.Mock{}, true, false, 1, false},
		{"webhook only, failed does not latch", nil, &notify.Mock{Err: errors.New("502")}, false, false, 1, false},
		{"both succeed", &actuator.Mock{Switched: true}, &notify.Mock{}, true, true, 1, false},
		// The change this test locks in: once k8s is enabled it is what actually
		// moves the applications, so it alone decides the latch. The webhook
		// still fires and its failure is still an error + a metric, but it can
		// no longer hold a completed failover open. Since the switch DID happen,
		// runSwitch must say so instead of leaving the operator with only a bare
		// webhook_failed line.
		{"k8s succeeded, webhook failed still latches", &actuator.Mock{Switched: true}, &notify.Mock{Err: errors.New("502")}, true, true, 1, true},
		{"k8s already on secondary, webhook failed still latches", &actuator.Mock{Switched: false}, &notify.Mock{Err: errors.New("502")}, true, true, 1, true},
		{"k8s errored, webhook delivered does not latch", &actuator.Mock{Err: errors.New("boom")}, &notify.Mock{}, false, true, 1, false},
		// The regression this row locks in: on a tick where NEITHER path moved
		// anything, nothing may claim the Kubernetes actuator performed the
		// switch. Before this fix webhook_failed's own wording made exactly that
		// claim whenever k8s was enabled, regardless of whether k8s itself had
		// just errored.
		{"k8s errored, webhook also failed: no latch, no dropped claim", &actuator.Mock{Err: errors.New("configmap boom")}, &notify.Mock{Err: errors.New("502")}, false, true, 1, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			d := switchDeps{Log: slog.New(slog.NewTextHandler(&buf, nil))}
			if tc.act != nil {
				d.Act = tc.act
			}
			if tc.note != nil {
				d.Notifier = tc.note
			}
			got := runSwitch(context.Background(), d, info, notify.Event{Event: "switch_required"})
			if got != tc.wantLatched {
				t.Errorf("runSwitch = %v, want %v", got, tc.wantLatched)
			}
			if tc.act != nil && tc.act.Called != tc.wantCalled {
				t.Errorf("actuator called = %v, want %v", tc.act.Called, tc.wantCalled)
			}
			if tc.note != nil && len(tc.note.Calls) != tc.wantNotify {
				t.Errorf("webhook deliveries = %d, want %d", len(tc.note.Calls), tc.wantNotify)
			}
			gotDropped := strings.Contains(buf.String(), "webhook_dropped")
			if gotDropped != tc.wantDropped {
				t.Errorf("webhook_dropped logged = %v, want %v; log:\n%s", gotDropped, tc.wantDropped, buf.String())
			}
		})
	}
}
