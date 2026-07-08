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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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
	probeTimeout := flag.Duration("probe-timeout", 2*time.Second, "per-ping bound so a probe against an unreachable cluster returns (DOWN) instead of wedging the loop; keep 2*probe-timeout < 3*interval so the liveness heartbeat stays fresh")
	failoverDelay := flag.Duration("failover-delay", 150*time.Second, "sustained DOWN before switch; set above the cluster auto-failover timeout")
	secondary := flag.String("secondary-conn", "", "connection string to switch to (active mode)")
	namespace := flag.String("namespace", "default", "k8s namespace (active mode)")
	configMap := flag.String("configmap", "cb-conn", "configmap holding the connstring (active mode)")
	configKey := flag.String("config-key", "connstring", "key in the configmap (active mode)")
	deployments := flag.String("deployments", "", "comma-separated deployments to roll (active mode)")
	dryRun := flag.Bool("dry-run", false, "active mode: log the switch but make no changes")
	tlsCertPath := flag.String("tls-cert-path", "", "path to a PEM CA cert to trust for couchbases:// TLS")
	tlsSkipVerify := flag.Bool("tls-skip-verify", false, "skip TLS server-certificate verification (insecure)")
	flag.Parse()

	// Liveness (/healthz) trips when the loop goes 3*interval without a tick. Each
	// iteration runs two sequential pings, each bounded by probe-timeout, so keep
	// 2*probe-timeout < 3*interval or a probe against a down cluster can starve the
	// heartbeat and get the pod restarted instead of switched.
	if 2*(*probeTimeout) >= 3*(*interval) {
		log.Printf("WARNING: 2*probe-timeout (%s) >= liveness window 3*interval (%s); lower --probe-timeout or raise --interval", 2*(*probeTimeout), 3*(*interval))
	}

	if os.Getenv("GOCB_VERBOSE") != "" {
		gocb.SetLogger(gocb.VerboseStdioLogger())
	}

	sec, err := buildSecurityConfig(*tlsCertPath, *tlsSkipVerify)
	if err != nil {
		log.Fatal(err)
	}

	cluster, err := gocb.Connect(*conn, gocb.ClusterOptions{
		Authenticator:  gocb.PasswordAuthenticator{Username: *user, Password: *pass},
		SecurityConfig: sec,
	})
	if err != nil {
		log.Fatal(err)
	}
	b := cluster.Bucket(*bucket)
	_ = b.WaitUntilReady(5*time.Second, nil)

	prober := &svchealth.GocbProber{Cluster: cluster, Bucket: b, Timeout: *probeTimeout}
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
	alreadySwitched := reconcileAlreadySwitched(context.Background(), k8sClient, *namespace, *configMap, *configKey, *secondary)
	if alreadySwitched {
		log.Printf("startup: configmap already on secondary %q; adopting switched state, apps NOT rolled, primary DOWN is expected", *secondary)
	}
	machine := state.New(state.Config{FailoverDelay: *failoverDelay, AlreadySwitched: alreadySwitched})
	log.Printf("active mode: failover-delay=%s secondary=%q deployments=%q dryRun=%v alreadySwitched=%v", *failoverDelay, *secondary, *deployments, *dryRun, alreadySwitched)

	primaryRegion := regionLabel(*conn)
	secondaryRegion := regionLabel(*secondary)
	// When we booted into an already-switched state, the secondary is the active
	// region; reflect that instead of the default primary=1.
	if alreadySwitched {
		metrics.ActiveRegion.WithLabelValues(secondaryRegion).Set(1)
	} else {
		metrics.ActiveRegion.WithLabelValues(primaryRegion).Set(1)
	}

	var secondaryProber *svchealth.GocbProber
	if *secondary != "" {
		if sc, err := gocb.Connect(*secondary, gocb.ClusterOptions{
			Authenticator:  gocb.PasswordAuthenticator{Username: *user, Password: *pass},
			SecurityConfig: sec,
		}); err == nil {
			sb := sc.Bucket(*bucket)
			_ = sb.WaitUntilReady(5*time.Second, nil)
			secondaryProber = &svchealth.GocbProber{Cluster: sc, Bucket: sb, Timeout: *probeTimeout}
		} else {
			log.Printf("secondary connect failed (guard will treat secondary as DOWN): %v", err)
		}
	}

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	for range ticker.C {
		hb.Tick()
		probes, _ := prober.Probe(context.Background())
		rep := svchealth.Compute(probes, crit, time.Now().UTC().Format(time.RFC3339))
		firstEval.Store(true)
		metrics.LoopLastTick.Set(float64(time.Now().Unix()))
		// DEGRADED counts as up: the critical path is healthy (mirrors /health/couchbase 200).
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
		res := machine.Observe(rep.Status)
		metrics.SustainedDownSeconds.Set(machine.DownSeconds(time.Now()))
		log.Printf("status=%s reason=%q switchRequired=%v", rep.Status, rep.Reason, res.SwitchRequired)
		if res.SwitchRequired {
			if *secondary == "" {
				log.Printf("switch required but --secondary-conn empty; skipping")
				continue
			}
			secStatus := "DOWN"
			if secondaryProber != nil {
				sp, _ := secondaryProber.Probe(context.Background())
				secStatus = svchealth.Compute(sp, crit, time.Now().UTC().Format(time.RFC3339)).Status
			}
			secUp := 0.0
			if secondaryReady(secStatus) {
				secUp = 1.0
			}
			metrics.SecondaryUp.Set(secUp)
			if !secondaryReady(secStatus) {
				log.Printf("switch held: secondary not ready (status=%s); will retry next tick", secStatus)
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
				metrics.ActiveRegion.WithLabelValues(primaryRegion).Set(0)
				metrics.ActiveRegion.WithLabelValues(secondaryRegion).Set(1)
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

// reconcileAlreadySwitched reads the connstring ConfigMap once at startup and
// reports whether it already points to the secondary — i.e. a prior observer
// instance already switched. Read failure or empty secondary -> false (assume
// not switched, fail toward acting; the delay + secondary guard still protect).
func reconcileAlreadySwitched(ctx context.Context, client kubernetes.Interface, namespace, configMap, configKey, secondary string) bool {
	if secondary == "" {
		return false
	}
	cm, err := client.CoreV1().ConfigMaps(namespace).Get(ctx, configMap, metav1.GetOptions{})
	if err != nil {
		log.Printf("startup configmap read failed (assuming not switched): %v", err)
		return false
	}
	return cm.Data[configKey] == secondary
}

// secondaryReady reports whether a computed secondary status permits a switch.
// Only a hard DOWN holds the switch; UP and DEGRADED (critical services up) proceed.
func secondaryReady(status string) bool { return status != "DOWN" }

// regionLabel extracts a short region name from a couchbase:// connstring, e.g.
// "couchbase://region-a-srv.region-a.svc" -> "region-a". Empty conn -> "none".
func regionLabel(conn string) string {
	if conn == "" {
		return "none"
	}
	h := conn
	if i := strings.Index(h, "://"); i >= 0 {
		h = h[i+3:]
	}
	if i := strings.Index(h, "."); i >= 0 {
		h = h[:i]
	}
	return strings.TrimSuffix(h, "-srv")
}
