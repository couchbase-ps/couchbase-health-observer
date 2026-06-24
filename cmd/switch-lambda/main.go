// Command switch-lambda is the SNS-triggered entrypoint for the distributed-quorum path.
// On the CloudWatch quorum alarm it switches the connection-string ConfigMap to the
// secondary cluster and rolls the dependent Deployments, reusing the same actuator as the
// centralized observer's active mode. Acts only on the ALARM transition (failback is
// manual) and is idempotent.
package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/switchhandler"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	cfg := actuator.Config{
		Namespace:   getenv("NAMESPACE", "default"),
		ConfigMap:   getenv("CONFIGMAP", "cb-conn"),
		ConfigKey:   getenv("CONFIG_KEY", "connstring"),
		Deployments: splitNonEmpty(os.Getenv("DEPLOYMENTS")),
		Secondary:   os.Getenv("SECONDARY_CONN"),
		DryRun:      os.Getenv("DRY_RUN") == "true",
	}
	h := switchhandler.New(&actuator.K8sActuator{Client: mustClientset(), Cfg: cfg})
	log.Printf("switch-lambda ready: namespace=%s configmap=%s deployments=%q secondary=%q dryRun=%v",
		cfg.Namespace, cfg.ConfigMap, cfg.Deployments, cfg.Secondary, cfg.DryRun)

	// One-shot mode: if ONESHOT_EVENT holds an SNS event JSON, process it once and exit.
	// Used by the kind e2e to drive the real binary against a cluster without the Lambda
	// runtime. Otherwise run as a normal Lambda.
	if ev := os.Getenv("ONESHOT_EVENT"); ev != "" {
		if err := h.Handle(context.Background(), []byte(ev)); err != nil {
			log.Fatalf("oneshot handle: %v", err)
		}
		return
	}

	lambda.Start(func(ctx context.Context, raw json.RawMessage) error {
		return h.Handle(ctx, raw)
	})
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// splitNonEmpty splits a comma list, dropping empties so an unset DEPLOYMENTS does not
// become a single "" entry the actuator would try to roll.
func splitNonEmpty(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// mustClientset builds a Kubernetes client. KUBECONFIG (set for the kind e2e or via a
// mounted kubeconfig in the Lambda) takes precedence; otherwise in-cluster config. Real
// EKS access from Lambda is granted by an EKS access entry mapping the Lambda role (see
// deploy/aws/lambda/README.md); the kubeconfig/token wiring is environment-specific.
func mustClientset() kubernetes.Interface {
	var cfg *rest.Config
	var err error
	if kc := os.Getenv("KUBECONFIG"); kc != "" {
		cfg, err = clientcmd.BuildConfigFromFlags("", kc)
	} else {
		cfg, err = rest.InClusterConfig()
	}
	if err != nil {
		log.Fatalf("k8s config: %v", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("k8s client: %v", err)
	}
	return cs
}
