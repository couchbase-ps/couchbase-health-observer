//go:build live

package eksauth

import (
	"context"
	"os"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// TestLiveClientset exercises the real STS-token path against a live EKS cluster. Run with
// AWS creds whose IAM principal has an EKS access entry:
//
//	AWS_PROFILE=... AWS_REGION=... EKS_CLUSTER_NAME=... go test -tags live ./pkg/eksauth -run TestLiveClientset -v
func TestLiveClientset(t *testing.T) {
	name := os.Getenv("EKS_CLUSTER_NAME")
	if name == "" {
		t.Skip("set EKS_CLUSTER_NAME")
	}
	cs, err := Clientset(context.Background(), name)
	if err != nil {
		t.Fatalf("build client: %v", err)
	}
	cm, err := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("get configmap (token accepted?): %v", err)
	}
	t.Logf("OK: read cb-conn = %q", cm.Data["connstring"])
}
