package actuator

import (
	"context"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func seed() *fake.Clientset {
	return fake.NewSimpleClientset(
		&corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Name: "cb-conn", Namespace: "default"},
			Data:       map[string]string{"connstring": "couchbase://region-a"},
		},
		&appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "mock-app", Namespace: "default"}},
	)
}

func newActuator(cs *fake.Clientset, dryRun bool) *K8sActuator {
	return &K8sActuator{
		Client: cs,
		Cfg: Config{
			Namespace: "default", ConfigMap: "cb-conn", ConfigKey: "connstring",
			Deployments: []string{"mock-app"}, Secondary: "couchbase://region-b", DryRun: dryRun,
		},
		Now: func() string { return "2026-06-22T00:00:00Z" },
	}
}

func TestSwitchPatchesAndRolls(t *testing.T) {
	cs := seed()
	switched, err := newActuator(cs, false).Switch(context.Background())
	if err != nil || !switched {
		t.Fatalf("switched=%v err=%v", switched, err)
	}
	cm, _ := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	if cm.Data["connstring"] != "couchbase://region-b" {
		t.Errorf("connstring=%q, want region-b", cm.Data["connstring"])
	}
	dep, _ := cs.AppsV1().Deployments("default").Get(context.Background(), "mock-app", metav1.GetOptions{})
	if dep.Spec.Template.Annotations["observer/restartedAt"] != "2026-06-22T00:00:00Z" {
		t.Errorf("deployment not rolled: %v", dep.Spec.Template.Annotations)
	}
}

func TestSwitchIdempotent(t *testing.T) {
	cs := seed()
	cm, _ := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	cm.Data["connstring"] = "couchbase://region-b"
	cs.CoreV1().ConfigMaps("default").Update(context.Background(), cm, metav1.UpdateOptions{})

	switched, err := newActuator(cs, false).Switch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if switched {
		t.Error("expected no-op when already on secondary")
	}
}

func TestSwitchDryRun(t *testing.T) {
	cs := seed()
	switched, err := newActuator(cs, true).Switch(context.Background())
	if err != nil || !switched {
		t.Fatalf("dry-run should report intent: switched=%v err=%v", switched, err)
	}
	cm, _ := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	if cm.Data["connstring"] != "couchbase://region-a" {
		t.Error("dry-run must not mutate the configmap")
	}
}
