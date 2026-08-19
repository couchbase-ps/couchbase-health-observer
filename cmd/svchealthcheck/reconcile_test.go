package main

import (
	"context"
	"strings"
	"testing"

	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func cmIn(ns string, data map[string]string) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "cb-conn", Namespace: ns},
		Data:       data,
	}
}

func TestReconcileAlreadySwitched(t *testing.T) {
	const sec = "couchbase://region-b-srv.region-b.svc"
	const pri = "couchbase://region-a-srv.region-a.svc"
	onSec := map[string]string{"connstring": sec}
	onPri := map[string]string{"connstring": pri}
	bothRefs := []actuator.Ref{{Namespace: "default", Name: "cb-conn"}, {Namespace: "app-b", Name: "cb-conn"}}

	// wantStale lists the refs that are NOT on the secondary, so a mixed startup
	// state can be named in the logs instead of looking like a cold start.
	cases := []struct {
		name      string
		objs      []*corev1.ConfigMap
		refs      []actuator.Ref
		secondary string
		want      bool
		wantStale []string
	}{
		{"single on secondary -> switched",
			[]*corev1.ConfigMap{cmIn("default", onSec)},
			[]actuator.Ref{{Namespace: "default", Name: "cb-conn"}}, sec, true, nil},
		{"single on primary -> not switched",
			[]*corev1.ConfigMap{cmIn("default", onPri)},
			[]actuator.Ref{{Namespace: "default", Name: "cb-conn"}}, sec, false,
			[]string{"default/cb-conn"}},
		{"all namespaces on secondary -> switched",
			[]*corev1.ConfigMap{cmIn("default", onSec), cmIn("app-b", onSec)}, bothRefs, sec, true, nil},
		{"mixed namespaces -> not switched, stale one named",
			[]*corev1.ConfigMap{cmIn("default", onSec), cmIn("app-b", onPri)}, bothRefs, sec, false,
			[]string{"app-b/cb-conn"}},
		{"one configmap missing -> not switched, unreadable one is stale",
			[]*corev1.ConfigMap{cmIn("default", onSec)}, bothRefs, sec, false,
			[]string{"app-b/cb-conn"}},
		{"no refs -> not switched",
			nil, nil, sec, false, nil},
		{"empty secondary -> not switched",
			[]*corev1.ConfigMap{cmIn("default", onSec)},
			[]actuator.Ref{{Namespace: "default", Name: "cb-conn"}}, "", false, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := fake.NewSimpleClientset()
			for _, o := range tc.objs {
				if _, err := client.CoreV1().ConfigMaps(o.Namespace).Create(context.Background(), o, metav1.CreateOptions{}); err != nil {
					t.Fatal(err)
				}
			}
			got, stale := reconcileAlreadySwitched(context.Background(), client, tc.refs, "connstring", tc.secondary)
			if got != tc.want {
				t.Fatalf("reconcileAlreadySwitched = %v, want %v", got, tc.want)
			}
			if refList(stale) != strings.Join(tc.wantStale, " ") {
				t.Fatalf("stale refs = %q, want %q", refList(stale), strings.Join(tc.wantStale, " "))
			}
		})
	}
}
