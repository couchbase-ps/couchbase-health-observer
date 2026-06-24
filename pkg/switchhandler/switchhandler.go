// Package switchhandler ties the SNS alarm event to the region-switch actuation. It is
// the Lambda's core logic, kept separate from the entrypoint so it is unit-testable with
// a mock actuator.
package switchhandler

import (
	"context"
	"log"

	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/event"
)

type Handler struct {
	act actuator.Actuator
}

func New(act actuator.Actuator) *Handler { return &Handler{act: act} }

// Handle parses the SNS-wrapped alarm and, only on the ALARM transition, actuates the
// region switch. OK transitions are ignored (failback is manual). The switch is
// idempotent, so a duplicate ALARM delivery is a no-op.
func (h *Handler) Handle(ctx context.Context, raw []byte) error {
	a, err := event.Parse(raw)
	if err != nil {
		return err
	}
	if !a.Actionable() {
		log.Printf("alarm %q state %q not actionable, ignoring (no auto-failback)", a.AlarmName, a.NewStateValue)
		return nil
	}
	switched, err := h.act.Switch(ctx)
	if err != nil {
		return err
	}
	if switched {
		log.Printf("alarm %q: SWITCHED to secondary", a.AlarmName)
	} else {
		log.Printf("alarm %q: already on secondary, no-op", a.AlarmName)
	}
	return nil
}
