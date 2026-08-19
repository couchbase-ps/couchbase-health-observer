package main

import (
	"reflect"
	"testing"
)

func TestParseActuators(t *testing.T) {
	cases := []struct {
		name       string
		list, mode string
		want       Actuators
		deprecated bool
		wantErr    bool
	}{
		{"empty is observe only", "", "", Actuators{}, false, false},
		{"k8s only", "k8s", "", Actuators{K8s: true}, false, false},
		{"webhook only", "webhook", "", Actuators{Webhook: true}, false, false},
		{"both", "k8s,webhook", "", Actuators{K8s: true, Webhook: true}, false, false},
		{"spaces and order ignored", " webhook , k8s ", "", Actuators{K8s: true, Webhook: true}, false, false},
		{"empty entries ignored", "k8s,,", "", Actuators{K8s: true}, false, false},
		{"unknown value errors", "k8s,sns", "", Actuators{}, false, true},
		{"deprecated mode=active means k8s", "", "active", Actuators{K8s: true}, true, false},
		{"deprecated mode=observe means none", "", "observe", Actuators{}, true, false},
		{"unknown mode errors", "", "banana", Actuators{}, false, true},
		{"list wins over mode", "webhook", "active", Actuators{Webhook: true}, true, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, deprecated, err := parseActuators(tc.list, tc.mode)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("parseActuators(%q,%q) = %+v, want error", tc.list, tc.mode, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseActuators(%q,%q): %v", tc.list, tc.mode, err)
			}
			if got != tc.want {
				t.Errorf("actuators = %+v, want %+v", got, tc.want)
			}
			if deprecated != tc.deprecated {
				t.Errorf("deprecated = %v, want %v", deprecated, tc.deprecated)
			}
		})
	}
}

func TestActuatorsAnyAndList(t *testing.T) {
	if (Actuators{}).Any() {
		t.Error("empty set reported Any() true")
	}
	both := Actuators{K8s: true, Webhook: true}
	if !both.Any() {
		t.Error("populated set reported Any() false")
	}
	if want := []string{"k8s", "webhook"}; !reflect.DeepEqual(both.List(), want) {
		t.Errorf("List() = %v, want %v", both.List(), want)
	}
	if want := []string{"webhook"}; !reflect.DeepEqual((Actuators{Webhook: true}).List(), want) {
		t.Errorf("List() = %v, want %v", (Actuators{Webhook: true}).List(), want)
	}
}
