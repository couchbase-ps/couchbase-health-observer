// Command svchealthcheck serves the SDK per-service health endpoint and, when
// at least one actuator is enabled, drives a region switch after the cluster
// stays DOWN past FailoverDelay.
//
//	--actuators empty (default): serve GET /health/couchbase only.
//	--actuators=k8s:             also run a poll loop -> state machine -> Kubernetes actuator.
//	--actuators=webhook:         also POST the switch request to an external endpoint.
//
// The two actuators combine, e.g. --actuators=k8s,webhook. The Kubernetes
// actuator patches every connstring ConfigMap named by --configmap and rolls
// every Deployment named by --deployments, each entry namespace-qualified.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"github.com/couchbase/gocb/v2"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/actuator"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/metrics"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/notify"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/obslog"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/probes"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/state"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/svchealth"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	mode := flag.String("mode", "", "DEPRECATED: observe | active. Use --actuators instead; removed next release")
	actuatorList := flag.String("actuators", "", "comma-separated actions on a switch: k8s, webhook (empty = observe only)")
	conn := flag.String("conn", "couchbase://localhost", "connection string")
	bucket := flag.String("bucket", "travel-sample", "bucket for KV ping")
	user := flag.String("user", "Administrator", "admin user")
	pass := flag.String("pass", "password", "admin pass")
	critical := flag.String("critical", "kv", "comma-separated critical services")
	addr := flag.String("addr", ":8080", "listen address")
	interval := flag.Duration("interval", 5*time.Second, "active poll interval")
	probeTimeout := flag.Duration("probe-timeout", 2*time.Second, "per-ping bound so a probe against an unreachable cluster returns (DOWN) instead of wedging the loop; keep 2*probe-timeout < 3*interval so the liveness heartbeat stays fresh")
	failoverDelay := flag.Duration("failover-delay", 150*time.Second, "sustained DOWN before switch; set above the cluster auto-failover timeout")
	secondary := flag.String("secondary-conn", "", "connection string to switch to (needed by every actuator)")
	namespace := flag.String("namespace", "default", "default k8s namespace for unqualified --configmap/--deployments entries (k8s actuator)")
	configMap := flag.String("configmap", "cb-conn", "comma list of connstring configmaps, each ns/name or bare name (k8s actuator)")
	configKey := flag.String("config-key", "connstring", "key in the configmap (k8s actuator)")
	deployments := flag.String("deployments", "", "comma list of deployments to roll, each ns/name or bare name (k8s actuator)")
	dryRun := flag.Bool("dry-run", false, "log the switch but make no changes (every actuator)")
	tlsCertPath := flag.String("tls-cert-path", "", "path to a PEM CA cert to trust for couchbases:// TLS")
	tlsSkipVerify := flag.Bool("tls-skip-verify", false, "skip TLS server-certificate verification (insecure)")
	webhookURL := flag.String("webhook-url", "", "switch webhook endpoint (required when --actuators includes webhook)")
	webhookUser := flag.String("webhook-user", "", "webhook basic-auth user (or env WEBHOOK_USER)")
	webhookPass := flag.String("webhook-pass", "", "webhook basic-auth password (or env WEBHOOK_PASS)")
	var webhookHeaders stringList
	flag.Var(&webhookHeaders, "webhook-header", "extra request header \"Key: Value\"; repeatable (or env WEBHOOK_HEADER, one per line)")
	webhookTimeout := flag.Duration("webhook-timeout", 3*time.Second, "per-attempt webhook timeout; keep (retries+1)*timeout + backoff < 3*interval")
	webhookRetries := flag.Int("webhook-retries", 2, "extra webhook attempts after the first")
	webhookCACert := flag.String("webhook-ca-cert", "", "path to a PEM CA cert to trust for the webhook TLS connection")
	webhookSkipVerify := flag.Bool("webhook-skip-verify", false, "skip webhook TLS server-certificate verification (insecure)")
	logLevel := flag.String("log-level", "info", "trace|debug|info|warn|error")
	flag.Parse()

	lvl, err := obslog.Parse(*logLevel)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	logger := obslog.NewHuman(os.Stderr, lvl)
	slog.SetDefault(logger)
	ctx := context.Background()

	acts, deprecatedMode, err := parseActuators(*actuatorList, *mode)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if deprecatedMode {
		// Suggest the set that is actually in force. Deriving it from acts.K8s
		// alone told a "--actuators=webhook --mode=active" operator to use
		// "--actuators=", which reads as "delete your actuator list".
		logger.Warn("mode_deprecated", "mode", *mode, "replacement", "--actuators="+strings.Join(acts.List(), ","))
	}
	// Every webhook input is validated here, at parse time. Doing it later (next
	// to the notifier assembly) meant a malformed header or an unreadable CA only
	// failed after gocb.Connect, WaitUntilReady, the HTTP server start and the
	// ConfigMap reconcile.
	var webhookParsedHeaders []notify.Header
	var webhookClient *http.Client
	if acts.Webhook {
		if *webhookURL == "" {
			fmt.Fprintln(os.Stderr, "--actuators includes webhook but --webhook-url is empty")
			os.Exit(2)
		}
		webhookParsedHeaders, err = resolveHeaders(webhookHeaders, "WEBHOOK_HEADER")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		webhookClient, err = notify.NewClient(*webhookCACert, *webhookSkipVerify, *webhookTimeout)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
	}

	// Liveness (/healthz) trips when the loop goes 3*interval without a tick. A
	// switching tick runs the primary ping, then the secondary ping (each bounded
	// by probe-timeout), then the webhook delivery, so ALL of that lands in one
	// tick. Warn on the SUM when the webhook actuator is on; the probe pair alone
	// is the whole budget otherwise.
	probeBudget := 2 * (*probeTimeout)
	window := 3 * (*interval)
	if acts.Webhook {
		webhookBudget := webhookWorstCase(*webhookTimeout, *webhookRetries)
		if worst := probeBudget + webhookBudget; worst >= window {
			logger.Warn("webhook_window_tight", "worst_case", worst,
				"probe_budget", probeBudget, "webhook_budget", webhookBudget, "window", window)
		}
	} else if probeBudget >= window {
		logger.Warn("liveness_window_tight", "twice_probe_timeout", probeBudget, "window", window)
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

	// Heartbeat is only meaningful when the poll loop runs (there is a loop to
	// stall). Observe-only keeps it nil -> liveness is a static 200.
	var hb *probes.Heartbeat
	if acts.Any() {
		hb = &probes.Heartbeat{}
	}
	var firstEval atomic.Bool // set true after the first health evaluation completes

	// K8s client is needed by the readiness check and the actuator, so it is
	// built only for the k8s actuator. A webhook-only observer needs no cluster
	// credentials at all.
	var k8sClient kubernetes.Interface
	if acts.K8s {
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
	// (k8s actuator) the K8s API is reachable. Re-checked every probe, so a later
	// API loss flips the pod NOT READY without ever restarting it.
	mux.HandleFunc("/readyz", probes.Readiness(func(ctx context.Context) error {
		if !firstEval.Load() {
			return fmt.Errorf("no health evaluation completed yet")
		}
		if acts.K8s {
			if _, err := k8sClient.Discovery().ServerVersion(); err != nil {
				return fmt.Errorf("k8s API unreachable: %v", err)
			}
		}
		return nil
	}))
	mux.Handle("/metrics", metrics.Handler())
	modeLabel := "observe"
	if acts.Any() {
		modeLabel = "active"
	}
	go func() {
		logger.Info("startup", "mode", modeLabel, "critical", *critical, "addr", *addr)
		log.Fatal(http.ListenAndServe(*addr, mux))
	}()

	if !acts.Any() {
		firstEval.Store(true) // observe-only: ready as soon as the server is up
		select {}             // just serve
	}

	// Cluster identities for the logs: a fixed role (primary = --conn, secondary
	// = --secondary-conn) plus the addresses (all hosts, scheme+port stripped).
	// Per-tick lines use the short role; the startup mapping and the
	// switch-narrative lines carry role + address, e.g. "primary (10.0.1.5, 10.0.1.6)".
	primaryAddr := obslog.AddressList(*conn)
	secondaryAddr := obslog.AddressList(*secondary)
	primaryDisp := "primary (" + primaryAddr + ")"
	secondaryDisp := "secondary (" + secondaryAddr + ")"

	// Everything Kubernetes-specific lives behind acts.K8s: the targets, the
	// actuator itself, and the ConfigMap reconcile. Only the k8s actuator owns
	// state we can read back, so a webhook-only observer starts unswitched.
	var cmRefs, depRefs []actuator.Ref
	var act actuator.Actuator // MUST stay a nil interface when k8s is off: a typed-nil *K8sActuator is not nil
	alreadySwitched := false
	if acts.K8s {
		// Required, not merely parsed: an empty list can never converge, so the
		// loop must not start in that config.
		cmRefs, err = actuator.ParseRefsRequired(*configMap, *namespace)
		if err != nil {
			log.Fatalf("--configmap: %v", err)
		}
		depRefs, err = actuator.ParseRefs(*deployments, *namespace)
		if err != nil {
			log.Fatalf("--deployments: %v", err)
		}
		// A Deployment target whose namespace has no ConfigMap target rolls once and is
		// then skipped forever, on a connstring this observer never patches. Warn, not
		// fatal: the copy could be synced there by other tooling.
		if unpaired := actuator.UnpairedNamespaces(cmRefs, depRefs); len(unpaired) > 0 {
			logger.Warn("target_namespace_unpaired", "namespaces", strings.Join(unpaired, " "), "count", len(unpaired))
		}
		act = &actuator.K8sActuator{Client: k8sClient, Log: logger, Cfg: actuator.Config{
			ConfigMaps: cmRefs, ConfigKey: *configKey,
			Deployments: depRefs, Secondary: *secondary, DryRun: *dryRun,
		}}

		var staleRefs []actuator.Ref
		alreadySwitched, staleRefs = reconcileAlreadySwitched(ctx, k8sClient, cmRefs, *configKey, *secondary)
		switch {
		case alreadySwitched:
			logger.Info("adopt_switched", "secondary", secondaryDisp)
		case len(staleRefs) > 0 && len(staleRefs) < len(cmRefs):
			// Some ConfigMaps hold the secondary and some do not: a prior instance died
			// mid-fan-out. The switch stays pending (the whole delay is served again),
			// so name the apps still on the old cluster instead of staying silent.
			logger.Warn("adopt_mixed", "pending", refList(staleRefs),
				"pending_count", len(staleRefs), "total", len(cmRefs), "secondary", secondaryDisp)
		}
	}
	machine := state.New(state.Config{FailoverDelay: *failoverDelay, AlreadySwitched: alreadySwitched})
	logger.Info("clusters", "primary", primaryAddr, "secondary", secondaryAddr)
	logger.Info("active_config", "failover_delay", *failoverDelay,
		"configmaps", refList(cmRefs), "deployments", refList(depRefs),
		"dry_run", *dryRun, "already_switched", alreadySwitched,
		"actuators", strings.Join(acts.List(), ","))

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
			logger.Warn("secondary_connect_failed", "err", err)
		}
	}

	activeRole := "primary"
	activeDisp := primaryDisp
	if alreadySwitched {
		activeRole = "secondary"
		activeDisp = secondaryDisp
	}
	lastStatus := ""                  // forces INFO on the first tick
	var lastHosts map[string]struct{} // nil until the first round is seen

	// Like act, the notifier stays a nil interface when the webhook actuator is
	// off, which is how runSwitch knows to skip that path.
	var notifier notify.Notifier
	if acts.Webhook {
		headers, client := webhookParsedHeaders, webhookClient // validated at startup
		whUser := resolveCred(*webhookUser, "WEBHOOK_USER")
		if *webhookSkipVerify {
			logger.Warn("webhook_insecure", "url", notify.RedactURL(*webhookURL))
		}
		verify := "on"
		if *webhookSkipVerify {
			verify = "OFF"
		}
		logger.Info("webhook_target", "url", notify.RedactURL(*webhookURL), "auth", authSummary(whUser, headers),
			"verify", verify, "timeout", *webhookTimeout, "retries", *webhookRetries)
		notifier = &notify.HTTP{
			URL: *webhookURL, User: whUser, Pass: resolveCred(*webhookPass, "WEBHOOK_PASS"),
			Headers: headers, Client: client, Retries: *webhookRetries,
			DryRun: *dryRun, Log: logger,
		}
	}

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()
	for range ticker.C {
		hb.Tick()
		probeSet, _ := prober.Probe(ctx)
		now := time.Now().UTC()
		rep := svchealth.Compute(probeSet, crit, now.Format(time.RFC3339))
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

		// DEBUG: one summary line per tick. TRACE: the full per-node breakdown
		// (which node, which service) — the per-endpoint detail lives here, no
		// separate line-per-ping.
		nodes := svchealth.ByNode(probeSet)
		healthy, total := svchealth.NodeSummary(nodes)
		logger.Debug("cluster_detail", "listening", activeRole, "primary_conn", *conn,
			"secondary_conn", *secondary, "nodes", fmt.Sprintf("%d/%d", healthy, total))
		logger.Log(ctx, obslog.LevelTrace, "cluster_nodes", "region", activeRole, "nodes", svchealth.RenderNodes(nodes))

		// Cluster-map delta (INFO added / WARN removed / INFO new map on change).
		cur := svchealth.HostSet(probeSet)
		if lastHosts == nil {
			logger.Info("cluster_map", "nodes", sortedHosts(cur))
		} else {
			added, removed := svchealth.DiffHosts(lastHosts, cur)
			for _, h := range removed {
				logger.Warn("cluster_map_change", "action", "removed", "host", h, "cluster", activeRole)
			}
			for _, h := range added {
				logger.Info("cluster_map_change", "action", "added", "host", h, "cluster", activeRole)
			}
			if len(added)+len(removed) > 0 {
				logger.Info("cluster_map", "nodes", sortedHosts(cur))
			}
		}
		lastHosts = cur

		// Countdown start: first DOWN of a new window, not yet switched.
		changed := rep.Status != lastStatus
		if rep.Status == "DOWN" && changed && !machine.Switched() {
			logger.Info("failover_countdown_start", "delay", *failoverDelay, "secondary", secondaryDisp, "active_region", activeDisp)
		}

		// Health line: INFO on change, DEBUG steady. Carries switched + active_region.
		logger.Log(ctx, healthLevel(changed), "health",
			"status", rep.Status, "reason", rep.Reason, "switch_required", res.SwitchRequired,
			"switched", machine.Switched(), "active_region", activeRole,
			"sustained_down_s", machine.DownSeconds(time.Now()))
		lastStatus = rep.Status

		if res.SwitchRequired {
			if *secondary == "" {
				logger.Warn("switch_skipped", "reason", "secondary_conn_empty")
				continue
			}
			secStatus := "DOWN"
			if secondaryProber != nil {
				sp, _ := secondaryProber.Probe(ctx)
				secStatus = svchealth.Compute(sp, crit, time.Now().UTC().Format(time.RFC3339)).Status
			}
			secUp := 0.0
			if secondaryReady(secStatus) {
				secUp = 1.0
			}
			metrics.SecondaryUp.Set(secUp)
			if !secondaryReady(secStatus) {
				logger.Warn("switch_held", "reason", "secondary_not_ready", "secondary_status", secStatus)
				continue
			}
			logger.Info("switch_required", "active_region", activeDisp, "secondary", secondaryDisp)
			ev := newSwitchEvent(acts, rep.Reason, machine.DownSeconds(time.Now()),
				notify.Endpoint{Role: "primary", Conn: *conn, Label: primaryRegion, Nodes: strings.Fields(sortedHosts(cur))},
				notify.Endpoint{Role: "secondary", Conn: *secondary, Label: secondaryRegion, Status: secStatus},
				cmRefs, depRefs, *dryRun)
			deps := switchDeps{Act: act, Notifier: notifier, Log: logger}
			info := switchInfo{FromDisp: primaryDisp, ToDisp: secondaryDisp, SecondaryConn: *secondary, PrimaryNodes: sortedHosts(cur)}
			// runSwitch's bool follows whichever path can actually move the
			// applications (k8s alone when enabled, else the webhook), so one
			// gate covers the state machine latch and the active-region flip.
			if runSwitch(ctx, deps, info, ev) {
				machine.MarkSwitched()
				metrics.ActiveRegion.WithLabelValues(primaryRegion).Set(0)
				metrics.ActiveRegion.WithLabelValues(secondaryRegion).Set(1)
				activeRole, activeDisp = "secondary", secondaryDisp
			}
		}
	}
}

// refList renders refs as a space-joined "ns/name ns/name" string for log fields.
func refList(refs []actuator.Ref) string {
	out := make([]string, 0, len(refs))
	for _, r := range refs {
		out = append(out, r.String())
	}
	return strings.Join(out, " ")
}

// sortedHosts renders a host set as a sorted space-joined string for log fields.
func sortedHosts(set map[string]struct{}) string {
	hs := make([]string, 0, len(set))
	for h := range set {
		hs = append(hs, h)
	}
	sort.Strings(hs)
	return strings.Join(hs, " ")
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
		log.Fatalf("k8s config (the k8s actuator needs in-cluster or KUBECONFIG): %v", err)
	}
	cfg.Timeout = 5 * time.Second // bound readiness ServerVersion() + actuator calls
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("k8s client: %v", err)
	}
	return cs
}

// reconcileAlreadySwitched reads every connstring ConfigMap once at startup and
// reports whether they ALL already point to the secondary, i.e. a prior observer
// instance completed the switch. Mixed state, a read failure, no refs, or an empty
// secondary all report false: the observer then treats the switch as still pending
// and converges the rest, which is the safe direction (the failover delay and the
// secondary-readiness guard still gate any actual switch).
//
// It also returns the refs that are NOT on the secondary (unreadable ones included),
// so a crash mid-fan-out can be reported by name instead of looking like a cold start.
// Every ref is read, even after one fails, to keep that list complete.
func reconcileAlreadySwitched(ctx context.Context, client kubernetes.Interface, refs []actuator.Ref, configKey, secondary string) (bool, []actuator.Ref) {
	if secondary == "" || len(refs) == 0 {
		return false, nil
	}
	var stale []actuator.Ref
	for _, ref := range refs {
		cm, err := client.CoreV1().ConfigMaps(ref.Namespace).Get(ctx, ref.Name, metav1.GetOptions{})
		if err != nil {
			log.Printf("startup configmap read failed for %s (assuming not switched): %v", ref, err)
			stale = append(stale, ref)
			continue
		}
		if cm.Data[configKey] != secondary {
			stale = append(stale, ref)
		}
	}
	return len(stale) == 0, stale
}

// secondaryReady reports whether a computed secondary status permits a switch.
// Only a hard DOWN holds the switch; UP and DEGRADED (critical services up) proceed.
func secondaryReady(status string) bool { return status != "DOWN" }

// regionLabel extracts a short region name from a couchbase:// connstring, e.g.
// "couchbase://region-a-srv.region-a.svc" -> "region-a". Empty conn -> "none".
// regionLabel is the short cluster label used for metrics + log fields. It
// delegates to obslog.ClusterLabel so DNS srv names and IPv4 connstrings
// (Emirates) are labeled the same way everywhere.
func regionLabel(conn string) string { return obslog.ClusterLabel(conn) }
