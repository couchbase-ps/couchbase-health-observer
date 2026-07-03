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
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"github.com/couchbase/gocb/v2"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/metrics"
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
	var firstEval atomic.Bool // set true after the first health evaluation completes

	// K8s client is needed by the readiness check (active mode) and the actuator.
	var k8sClient kubernetes.Interface
	if *mode == "active" {
		k8sClient = mustK8sClient()
	}

	// /health/couchbase always served (probes fresh per request).
	mux := http.NewServeMux()
	mux.Handle("/health/couchbase", &svchealth.Handler{Prober: prober, Critical: crit})
	// Liveness fails ONLY when the active loop stalls (>3x interval). NEVER point
	// this at /health/couchbase: a real DB outage would then restart the observer
	// exactly when it must act.
	mux.HandleFunc("/healthz", probes.Liveness(hb, 3*(*interval), time.Now))
	// Readiness: config parsed (implicit post-flag.Parse) + first evaluation done +
	// (active mode) the K8s API is reachable. Re-checked every probe, so a later
	// API loss flips the pod NOT READY without ever restarting it.
	mux.HandleFunc("/readyz", probes.Readiness(func(ctx context.Context) error {
		if !firstEval.Load() {
			return fmt.Errorf("no health evaluation completed yet")
		}
		if *mode == "active" {
			if _, err := k8sClient.Discovery().ServerVersion(); err != nil {
				return fmt.Errorf("k8s API unreachable: %v", err)
			}
		}
		return nil
	}))
	mux.Handle("/metrics", metrics.Handler())
	go func() {
		log.Printf("listening on %s (mode=%s critical=%s)", *addr, *mode, *critical)
		log.Fatal(http.ListenAndServe(*addr, mux))
	}()

	if *mode != "active" {
		firstEval.Store(true) // observe-only: ready as soon as the server is up
		select {}             // just serve
	}

	// Active mode: build the actuator (reusing the client made for readiness) and run the loop.
	act := &actuator.K8sActuator{Client: k8sClient, Cfg: actuator.Config{
		Namespace: *namespace, ConfigMap: *configMap, ConfigKey: *configKey,
		Deployments: strings.Split(*deployments, ","), Secondary: *secondary, DryRun: *dryRun,
	}}
	machine := state.New(state.Config{FailoverDelay: *failoverDelay})
	log.Printf("active mode: failover-delay=%s secondary=%q deployments=%q dryRun=%v", *failoverDelay, *secondary, *deployments, *dryRun)

	primaryRegion := regionLabel(*conn)
	secondaryRegion := regionLabel(*secondary)
	metrics.ActiveRegion.WithLabelValues(primaryRegion).Set(1)

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	for range ticker.C {
		hb.Tick()
		probes, _ := prober.Probe(context.Background())
		rep := svchealth.Compute(probes, crit, time.Now().UTC().Format(time.RFC3339))
		firstEval.Store(true)
		metrics.LoopLastTick.Set(float64(time.Now().Unix()))
		up := 0.0
		if rep.Status != "DOWN" {
			up = 1.0
		}
		metrics.CouchbaseUp.WithLabelValues(primaryRegion).Set(up)
		for svc, sh := range rep.Services {
			s := 0.0
			if sh.Status == "UP" {
				s = 1.0
			}
			metrics.ServiceUp.WithLabelValues(svc).Set(s)
		}
		metrics.SustainedDownSeconds.Set(machine.DownSeconds(time.Now()))
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
				metrics.FailoverErrors.Inc()
				log.Printf("actuation failed: %v", err)
			case switched:
				metrics.FailoverTotal.Inc()
				metrics.LastActuationSuccess.Set(float64(time.Now().Unix()))
				metrics.ActiveRegion.WithLabelValues(primaryRegion).Set(0)
				metrics.ActiveRegion.WithLabelValues(secondaryRegion).Set(1)
				log.Printf("SWITCHED to %s", *secondary)
			default:
				log.Printf("already on secondary, no-op")
			}
		}
	}
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
	cfg.Timeout = 5 * time.Second // bound readiness ServerVersion() + actuator calls
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("k8s client: %v", err)
	}
	return cs
}

// regionLabel extracts a short region name from a couchbase:// connstring, e.g.
// "couchbase://region-a-srv.region-a.svc" -> "region-a". Empty conn -> "none".
func regionLabel(conn string) string {
	if conn == "" {
		return "none"
	}
	h := strings.TrimPrefix(conn, "couchbase://")
	if i := strings.Index(h, "."); i >= 0 {
		h = h[:i]
	}
	return strings.TrimSuffix(h, "-srv")
}
