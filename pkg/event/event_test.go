package event

import "testing"

const alarmSNS = `{"Records":[{"Sns":{"Message":"{\"AlarmName\":\"cb-health-quorum-down\",\"NewStateValue\":\"ALARM\"}"}}]}`
const okSNS = `{"Records":[{"Sns":{"Message":"{\"AlarmName\":\"cb-health-quorum-down\",\"NewStateValue\":\"OK\"}"}}]}`

func TestActionableOnAlarm(t *testing.T) {
	a, err := Parse([]byte(alarmSNS))
	if err != nil {
		t.Fatal(err)
	}
	if !a.Actionable() {
		t.Error("ALARM transition should be actionable")
	}
	if a.AlarmName != "cb-health-quorum-down" {
		t.Errorf("alarm name = %q", a.AlarmName)
	}
}

func TestNotActionableOnOK(t *testing.T) {
	a, err := Parse([]byte(okSNS))
	if err != nil {
		t.Fatal(err)
	}
	if a.Actionable() {
		t.Error("OK transition must NOT be actionable (no auto-failback)")
	}
}

func TestEmptyRecordsNotActionable(t *testing.T) {
	a, err := Parse([]byte(`{"Records":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	if a.Actionable() {
		t.Error("an empty event must not be actionable")
	}
}
