package switchhandler

import (
	"context"
	"testing"

	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
)

const alarmSNS = `{"Records":[{"Sns":{"Message":"{\"AlarmName\":\"cb-health-quorum-down\",\"NewStateValue\":\"ALARM\"}"}}]}`
const okSNS = `{"Records":[{"Sns":{"Message":"{\"AlarmName\":\"cb-health-quorum-down\",\"NewStateValue\":\"OK\"}"}}]}`

func TestSwitchesOnAlarm(t *testing.T) {
	m := &actuator.Mock{Switched: true}
	if err := New(m).Handle(context.Background(), []byte(alarmSNS)); err != nil {
		t.Fatal(err)
	}
	if !m.Called {
		t.Error("expected the actuator to be called on ALARM")
	}
}

func TestIgnoresOK(t *testing.T) {
	m := &actuator.Mock{}
	if err := New(m).Handle(context.Background(), []byte(okSNS)); err != nil {
		t.Fatal(err)
	}
	if m.Called {
		t.Error("must not actuate on OK (no auto-failback)")
	}
}

func TestIgnoresEmptyEvent(t *testing.T) {
	m := &actuator.Mock{}
	if err := New(m).Handle(context.Background(), []byte(`{"Records":[]}`)); err != nil {
		t.Fatal(err)
	}
	if m.Called {
		t.Error("must not actuate on an empty event")
	}
}
