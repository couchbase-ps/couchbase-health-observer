// Package event parses the SNS-wrapped CloudWatch alarm notification that triggers a
// region switch. Only the ALARM transition is actionable; OK (recovery) is ignored so
// failback stays manual.
package event

import "encoding/json"

type Alarm struct {
	AlarmName     string `json:"AlarmName"`
	NewStateValue string `json:"NewStateValue"`
}

// Actionable is true only for the ALARM transition.
func (a Alarm) Actionable() bool { return a.NewStateValue == "ALARM" }

type snsEnvelope struct {
	Records []struct {
		Sns struct {
			Message string `json:"Message"`
		} `json:"Sns"`
	} `json:"Records"`
}

// Parse unwraps the SNS envelope and decodes the CloudWatch alarm message inside it.
// An event with no records returns a zero Alarm (not actionable), not an error.
func Parse(raw []byte) (Alarm, error) {
	var env snsEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return Alarm{}, err
	}
	var a Alarm
	if len(env.Records) == 0 {
		return a, nil
	}
	if err := json.Unmarshal([]byte(env.Records[0].Sns.Message), &a); err != nil {
		return a, err
	}
	return a, nil
}
