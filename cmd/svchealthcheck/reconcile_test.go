package main

import (
	"context"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func cm(data map[string]string) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "cb-conn", Namespace: "default"},
		Data:       data,
	}
}

func TestReconcileAlreadySwitched(t *testing.T) {
	const sec = "couchbase://region-b-srv.region-b.svc"
	cases := []struct {
		name      string
		objs      []*corev1.ConfigMap
		secondary string
		want      bool
	}{
		{"on secondary -> switched", []*corev1.ConfigMap{cm(map[string]string{"connstring": sec})}, sec, true},
		{"on primary -> not switched", []*corev1.ConfigMap{cm(map[string]string{"connstring": "couchbase://region-a-srv.region-a.svc"})}, sec, false},
		{"missing configmap -> not switched", nil, sec, false},
		{"empty secondary -> not switched", []*corev1.ConfigMap{cm(map[string]string{"connstring": sec})}, "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := fake.NewSimpleClientset()
			for _, o := range tc.objs {
				if _, err := client.CoreV1().ConfigMaps(o.Namespace).Create(context.Background(), o, metav1.CreateOptions{}); err != nil {
					t.Fatal(err)
				}
			}
			got := reconcileAlreadySwitched(context.Background(), client, "default", "cb-conn", "connstring", tc.secondary)
			if got != tc.want {
				t.Fatalf("reconcileAlreadySwitched = %v, want %v", got, tc.want)
			}
		})
	}
}
