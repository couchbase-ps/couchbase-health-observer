// Command svchealthcheck serves the SDK per-service health endpoint and, in
// active mode, drives a region switch when the cluster stays DOWN past
// FailoverDelay.
//
//	observe (default): serve GET /health/couchbase only.
//	active:            also run a poll loop -> state machine -> Kubernetes actuator.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/couchbase/gocb/v2"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/probes"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/state"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/svchealth"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	mode := flag.String("mode", "observe", "observe | active")
	conn := flag.String("conn", "couchbase://localhost", "connection string")
	bucket := flag.String("bucket", "travel-sample", "bucket for KV ping")
	user := flag.String("user", "Administrator", "admin user")
	pass := flag.String("pass", "password", "admin pass")
	critical := flag.String("critical", "kv", "comma-separated critical services")
	addr := flag.String("addr", ":8080", "listen address")
	interval := flag.Duration("interval", 5*time.Second, "active poll interval")
	failoverDelay := flag.Duration("failover-delay", 150*time.Second, "sustained DOWN before switch; set above the cluster auto-failover timeout")
	secondary := flag.String("secondary-conn", "", "connection string to switch to (active mode)")
	namespace := flag.String("namespace", "default", "k8s namespace (active mode)")
	configMap := flag.String("configmap", "cb-conn", "configmap holding the connstring (active mode)")
	configKey := flag.String("config-key", "connstring", "key in the configmap (active mode)")
	deployments := flag.String("deployments", "", "comma-separated deployments to roll (active mode)")
	dryRun := flag.Bool("dry-run", false, "active mode: log the switch but make no changes")
	flag.Parse()

	if os.Getenv("GOCB_VERBOSE") != "" {
		gocb.SetLogger(gocb.VerboseStdioLogger())
	}

	cluster, err := gocb.Connect(*conn, gocb.ClusterOptions{
		Authenticator: gocb.PasswordAuthenticator{Username: *user, Password: *pass},
	})
	if err != nil {
		log.Fatal(err)
	}
	b := cluster.Bucket(*bucket)
	_ = b.WaitUntilReady(5*time.Second, nil)

	prober := &svchealth.GocbProber{Cluster: cluster, Bucket: b}
	crit := strings.Split(*critical, ",")

	// Heartbeat is only meaningful in active mode (there is a loop to stall). In
	// observe mode it stays nil -> liveness is a static 200.
	var hb *probes.Heartbeat
	if *mode == "active" {
		hb = &probes.Heartbeat{}
	}

	// /health/couchbase always served (probes fresh per request).
	mux := http.NewServeMux()
	mux.Handle("/health/couchbase", &svchealth.Handler{Prober: prober, Critical: crit})
	// Liveness fails ONLY when the active loop stalls (>3x interval). NEVER point
	// this at /health/couchbase: a real DB outage would then restart the observer
	// exactly when it must act.
	mux.HandleFunc("/healthz", probes.Liveness(hb, 3*(*interval), time.Now))
	go func() {
		log.Printf("listening on %s (mode=%s critical=%s)", *addr, *mode, *critical)
		log.Fatal(http.ListenAndServe(*addr, mux))
	}()

	if *mode != "active" {
		select {} // observe-only: just serve
	}

	// Active mode: build the actuator and run the decision loop.
	act := buildActuator(*namespace, *configMap, *configKey, *secondary, strings.Split(*deployments, ","), *dryRun)
	machine := state.New(state.Config{FailoverDelay: *failoverDelay})
	log.Printf("active mode: failover-delay=%s secondary=%q deployments=%q dryRun=%v", *failoverDelay, *secondary, *deployments, *dryRun)

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	for range ticker.C {
		hb.Tick()
		probes, _ := prober.Probe(context.Background())
		rep := svchealth.Compute(probes, crit, time.Now().UTC().Format(time.RFC3339))
		res := machine.Observe(rep.Status)
		log.Printf("status=%s reason=%q switchRequired=%v", rep.Status, rep.Reason, res.SwitchRequired)
		if res.SwitchRequired {
			if *secondary == "" {
				log.Printf("switch required but --secondary-conn empty; skipping")
				continue
			}
			switched, err := act.Switch(context.Background())
			switch {
			case err != nil:
				log.Printf("actuation failed: %v", err)
			case switched:
				log.Printf("SWITCHED to %s", *secondary)
			default:
				log.Printf("already on secondary, no-op")
			}
		}
	}
}

func buildActuator(ns, cm, key, secondary string, deployments []string, dryRun bool) actuator.Actuator {
	cfg := actuator.Config{
		Namespace: ns, ConfigMap: cm, ConfigKey: key,
		Deployments: deployments, Secondary: secondary, DryRun: dryRun,
	}
	cs := mustK8sClient()
	return &actuator.K8sActuator{Client: cs, Cfg: cfg}
}

// mustK8sClient uses KUBECONFIG if set (local / kind), else in-cluster config.
func mustK8sClient() kubernetes.Interface {
	var cfg *rest.Config
	var err error
	if kc := os.Getenv("KUBECONFIG"); kc != "" {
		cfg, err = clientcmd.BuildConfigFromFlags("", kc)
	} else {
		cfg, err = rest.InClusterConfig()
	}
	if err != nil {
		log.Fatalf("k8s config (active mode needs in-cluster or KUBECONFIG): %v", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("k8s client: %v", err)
	}
	return cs
}
