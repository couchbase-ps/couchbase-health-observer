// Command switch-lambda is the SNS-triggered entrypoint for the distributed-quorum path.
// On the CloudWatch quorum alarm it switches the connection-string ConfigMaps to the
// secondary cluster and rolls the dependent Deployments, across every namespace named in
// CONFIGMAP / DEPLOYMENTS (entries are ns/name, or bare names using NAMESPACE as the
// default). Reuses the same actuator as the centralized observer's active mode. Acts only
// on the ALARM transition (failback is manual) and is idempotent.
package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"strings"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/eksauth"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/switchhandler"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	defaultNS := getenv("NAMESPACE", "default")
	// Required, not merely parsed: an empty list can never converge, and this
	// one-shot entrypoint has no retry loop to recover in.
	cmRefs, err := actuator.ParseRefsRequired(getenv("CONFIGMAP", "cb-conn"), defaultNS)
	if err != nil {
		log.Fatalf("CONFIGMAP: %v", err)
	}
	depRefs, err := actuator.ParseRefs(os.Getenv("DEPLOYMENTS"), defaultNS)
	if err != nil {
		log.Fatalf("DEPLOYMENTS: %v", err)
	}
	// A deployment target whose namespace has no configmap target rolls once and is
	// then skipped forever, on a connstring this switch never patches. Warn, not
	// fatal: the copy could be synced there by other tooling.
	if unpaired := actuator.UnpairedNamespaces(cmRefs, depRefs); len(unpaired) > 0 {
		log.Printf("WARNING: %d namespace(s) hold a deployment target but no configmap target: %s (those apps read a ConfigMap this switch never patches)",
			len(unpaired), strings.Join(unpaired, " "))
	}
	cfg := actuator.Config{
		ConfigMaps:  cmRefs,
		ConfigKey:   getenv("CONFIG_KEY", "connstring"),
		Deployments: depRefs,
		Secondary:   os.Getenv("SECONDARY_CONN"),
		DryRun:      os.Getenv("DRY_RUN") == "true",
	}
	h := switchhandler.New(&actuator.K8sActuator{Client: mustClientset(), Cfg: cfg})
	log.Printf("switch-lambda ready: configmaps=%v deployments=%v secondary=%q dryRun=%v",
		cfg.ConfigMaps, cfg.Deployments, cfg.Secondary, cfg.DryRun)

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

// mustClientset builds a Kubernetes client. Precedence:
//   - EKS_CLUSTER_NAME set: authenticate to that EKS cluster with the Lambda's IAM role
//     via an STS token (the role must be mapped through an EKS access entry).
//   - KUBECONFIG set: use it (kind e2e / local).
//   - otherwise: in-cluster config.
func mustClientset() kubernetes.Interface {
	if name := os.Getenv("EKS_CLUSTER_NAME"); name != "" {
		cs, err := eksauth.Clientset(context.Background(), name)
		if err != nil {
			log.Fatalf("eks client: %v", err)
		}
		return cs
	}
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
