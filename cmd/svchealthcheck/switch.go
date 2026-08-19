package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/metrics"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/notify"
)

// switchDeps holds the enabled actuation paths. A nil field means that path is
// disabled, which is how --actuators reaches this code.
type switchDeps struct {
	Act      actuator.Actuator
	Notifier notify.Notifier
	Log      *slog.Logger
}

// switchInfo carries the display strings the switch narrative logs use.
type switchInfo struct {
	FromDisp, ToDisp string
	SecondaryConn    string
	PrimaryNodes     string
}

// newSwitchEvent builds the webhook payload for one switch decision. ConfigMaps
// and Deployments describe the Kubernetes actuator, so they are set ONLY when
// acts.K8s is true: a webhook-only switch has no Kubernetes target to report
// (see pkg/notify/event.go and deploy/k8s/README.md for the contract). Both are
// rendered "ns/name", since one switch spans several namespaces. Every other
// field is populated unconditionally, exactly as passed in.
func newSwitchEvent(acts Actuators, reason string, sustainedDownS float64, from, to notify.Endpoint, configMaps, deployments []actuator.Ref, dryRun bool) notify.Event {
	ev := notify.Event{
		Event:          "switch_required",
		Reason:         reason,
		SustainedDownS: sustainedDownS,
		From:           from,
		To:             to,
		Actuators:      acts.List(),
		DryRun:         dryRun,
	}
	if acts.K8s {
		ev.ConfigMaps = refStrings(configMaps)
		ev.Deployments = refStrings(deployments)
	}
	return ev
}

// refStrings renders refs as "ns/name" payload entries. A nil/empty list stays
// nil so omitempty still drops the key.
func refStrings(refs []actuator.Ref) []string {
	if len(refs) == 0 {
		return nil
	}
	out := make([]string, 0, len(refs))
	for _, r := range refs {
		out = append(out, r.String())
	}
	return out
}

// runSwitch performs every enabled actuation for one switch decision and
// reports whether the state machine may latch (stop asking for a switch).
//
// The latch follows whichever enabled path can actually move the
// applications:
//
//   - k8s enabled: the latch follows the Kubernetes result ALONE. The
//     ConfigMap patch + Deployment roll is what really moves the
//     applications, so once that succeeds the failover is done regardless of
//     the webhook. The webhook still fires and a delivery failure is still
//     logged as an error and still counted in observer_webhook_total, but it
//     is a notification about a switch that already happened, not the switch
//     itself, so it must not hold the latch open and make the observer
//     re-run a completed failover every tick. Do NOT restore the old
//     "latch only when every enabled path succeeds" rule here: it makes a
//     dropped webhook POST mask a successful Kubernetes switch.
//   - k8s disabled (webhook-only): the webhook IS the actuator, so a failed
//     delivery must hold the latch and retry next tick, exactly as before.
//
// A held latch is safe to retry: the ConfigMap patch is an idempotent no-op,
// and only the failed path is really re-attempted.
//
// pkg/notify's webhook_failed line reports only the delivery failure; it has
// no visibility into the k8s actuator's outcome on the same tick. runSwitch is
// the one place that knows both, so when the webhook failed but k8s actually
// moved the applications (switched, or the already-there no-op), it alone
// logs webhook_dropped to say the switch went through anyway. When k8s did
// not move anything (disabled, or itself errored), it stays silent: the
// webhook_failed/actuation_error lines already tell the whole story, and
// claiming a Kubernetes switch that did not happen would not.
func runSwitch(ctx context.Context, d switchDeps, info switchInfo, ev notify.Event) bool {
	latch := true
	k8sMoved := false // true once the Kubernetes actuator has actually moved the applications (switched or already-there no-op)
	if d.Act != nil {
		switched, err := d.Act.Switch(ctx)
		switch {
		case err != nil:
			metrics.FailoverErrors.Inc()
			d.Log.Error("actuation_error", "err", err)
			latch = false
		case switched:
			metrics.FailoverTotal.Inc()
			metrics.LastActuationSuccess.Set(float64(time.Now().Unix()))
			d.Log.Info("switched", "from", info.FromDisp, "to", info.ToDisp,
				"secondary_conn", info.SecondaryConn, "primary_nodes", info.PrimaryNodes)
			k8sMoved = true
		default:
			d.Log.Info("switch_noop", "active_region", info.ToDisp)
			k8sMoved = true
		}
	}
	if d.Notifier != nil {
		// The notifier logs webhook_called / webhook_retry / webhook_failed itself;
		// none of that says whether a switch actually happened this tick, because
		// pkg/notify has no visibility into the k8s actuator's outcome. This is
		// the one place that knows both, so it is the one place allowed to say the
		// switch went through anyway.
		if err := d.Notifier.Notify(ctx, ev); err != nil {
			metrics.WebhookTotal.WithLabelValues("error").Inc()
			switch {
			case d.Act == nil:
				latch = false
			case k8sMoved:
				d.Log.Warn("webhook_dropped", "active_region", info.ToDisp, "err", err.Error())
			}
		} else {
			metrics.WebhookTotal.WithLabelValues("ok").Inc()
			metrics.WebhookLastSuccess.Set(float64(time.Now().Unix()))
		}
	}
	return latch
}
