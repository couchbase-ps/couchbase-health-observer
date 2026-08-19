package obslog

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
)

// NewHuman returns a logger that renders each event as a lean, human-readable
// line (Spring-app feel) instead of slog's key=value text:
//
//	15:37:48.060 INFO  health     Cluster DOWN - critical service "kv" 1/3 endpoints unreachable [region-a]; no switch yet
//
// Levels, event names, and attrs are unchanged — only the rendering differs, so
// a machine-readable (JSON) handler can be swapped in later without touching any
// call site.
func NewHuman(w io.Writer, level slog.Level) *slog.Logger {
	return slog.New(&humanHandler{w: w, level: level, mu: &sync.Mutex{}})
}

type humanHandler struct {
	w     io.Writer
	level slog.Level
	mu    *sync.Mutex
	attrs []slog.Attr
}

func (h *humanHandler) Enabled(_ context.Context, l slog.Level) bool { return l >= h.level }

func (h *humanHandler) Handle(_ context.Context, r slog.Record) error {
	fields := map[string]slog.Value{}
	for _, a := range h.attrs {
		fields[a.Key] = a.Value
	}
	r.Attrs(func(a slog.Attr) bool {
		fields[a.Key] = a.Value
		return true
	})
	comp, msg := renderEvent(r.Message, fields)
	line := fmt.Sprintf("%s %-5s %-9s %s\n", r.Time.Format("15:04:05.000"), levelLabel(r.Level), comp, msg)
	h.mu.Lock()
	defer h.mu.Unlock()
	_, err := io.WriteString(h.w, line)
	return err
}

func (h *humanHandler) WithAttrs(as []slog.Attr) slog.Handler {
	nh := *h
	nh.attrs = append(append([]slog.Attr{}, h.attrs...), as...)
	return &nh
}

func (h *humanHandler) WithGroup(string) slog.Handler { return h } // groups unused

func levelLabel(l slog.Level) string {
	switch {
	case l < slog.LevelDebug:
		return "TRACE"
	case l < slog.LevelInfo:
		return "DEBUG"
	case l < slog.LevelWarn:
		return "INFO"
	case l < slog.LevelError:
		return "WARN"
	default:
		return "ERROR"
	}
}

// ClusterLabel derives a short human label for a cluster from its connstring.
// DNS srv-style names collapse to the region
// ("couchbase://region-a-srv.region-a.svc" -> "region-a"); IP-literal
// connstrings (Emirates' setup) keep the full address rather than being
// truncated to the first octet ("couchbase://10.0.1.5:11210" -> "10.0.1.5",
// not "10"). A multi-host connstring uses the first host. Empty -> "none".
// IPv6 literals are not special-cased (Emirates is IPv4).
func ClusterLabel(conn string) string {
	if conn == "" {
		return "none"
	}
	h := conn
	if i := strings.Index(h, "://"); i >= 0 { // drop scheme
		h = h[i+3:]
	}
	if i := strings.IndexAny(h, ",/?"); i >= 0 { // first host of a multi-host connstring
		h = h[:i]
	}
	if i := strings.LastIndex(h, ":"); i >= 0 { // drop :port
		h = h[:i]
	}
	if net.ParseIP(h) != nil { // IP literal: keep the address as-is
		return h
	}
	if i := strings.Index(h, "."); i >= 0 { // DNS: first label...
		h = h[:i]
	}
	return strings.TrimSuffix(h, "-srv") // ...minus an -srv suffix
}

// AddressList renders every host in a connstring, scheme and port stripped,
// comma-joined — e.g. "couchbase://10.0.1.5:11210,10.0.1.6:11210" ->
// "10.0.1.5, 10.0.1.6". Unlike ClusterLabel it keeps ALL hosts (Couchbase
// connstrings list every seed node per Couchbase's recommendation) and does not
// collapse DNS names. Empty -> "none".
func AddressList(conn string) string {
	if conn == "" {
		return "none"
	}
	h := conn
	if i := strings.Index(h, "://"); i >= 0 { // drop scheme
		h = h[i+3:]
	}
	if i := strings.IndexAny(h, "/?"); i >= 0 { // drop any path/params
		h = h[:i]
	}
	hosts := strings.Split(h, ",")
	for i, host := range hosts {
		host = strings.TrimSpace(host)
		if j := strings.LastIndex(host, ":"); j >= 0 { // strip :port (IPv4/DNS; IPv6 not handled)
			host = host[:j]
		}
		hosts[i] = host
	}
	return strings.Join(hosts, ", ")
}

// renderEvent maps an event name + its fields to a (component, message) pair for
// the human line. Unknown events fall back to the event name plus its raw fields
// so nothing is ever silently dropped.
func renderEvent(event string, f map[string]slog.Value) (component, message string) {
	at := func(k string) string {
		if v, ok := f[k]; ok {
			return v.String()
		}
		return ""
	}

	switch event {
	case "startup":
		return "observer", fmt.Sprintf("Started in %s mode on %s (critical: %s)", at("mode"), at("addr"), at("critical"))
	case "clusters":
		return "observer", fmt.Sprintf("Clusters: primary=%s, secondary=%s", at("primary"), at("secondary"))
	case "active_config":
		return "observer", fmt.Sprintf("Config: failover-delay=%s configmaps=[%s] deployments=[%s] dry-run=%s already-switched=%s actuators=[%s]",
			at("failover_delay"), at("configmaps"), at("deployments"), at("dry_run"), at("already_switched"), at("actuators"))
	case "adopt_switched":
		return "observer", fmt.Sprintf("Adopting already-switched state: now on %s; apps not rolled, primary DOWN expected", at("secondary"))
	case "adopt_mixed":
		return "observer", fmt.Sprintf("Mixed startup state: %s of %s ConfigMaps not yet on %s: %s; switch still pending",
			at("pending_count"), at("total"), at("secondary"), at("pending"))
	case "target_namespace_unpaired":
		return "observer", fmt.Sprintf("%s namespace(s) hold a deployment target but no ConfigMap target: %s; those apps read a ConfigMap this observer never patches",
			at("count"), at("namespaces"))
	case "liveness_window_tight":
		return "observer", fmt.Sprintf("Liveness window tight: 2x probe-timeout %s >= 3x interval %s", at("twice_probe_timeout"), at("window"))
	case "secondary_connect_failed":
		return "observer", fmt.Sprintf("Secondary connect failed (treated as DOWN): %s", at("err"))

	case "health":
		region := at("active_region")
		switch at("status") {
		case "UP":
			return "health", fmt.Sprintf("%s UP - all critical services reachable", region)
		case "DEGRADED":
			return "health", fmt.Sprintf("%s DEGRADED - %s (active)", region, at("reason"))
		default: // DOWN
			tail := "no switch yet"
			if at("switched") == "true" {
				tail = "already switched, holding"
			} else if at("switch_required") == "true" {
				tail = "switch required"
			}
			down := ""
			if v, ok := f["sustained_down_s"]; ok && v.Kind() == slog.KindFloat64 && v.Float64() >= 1 {
				down = fmt.Sprintf("down %.0fs; ", v.Float64())
			}
			return "health", fmt.Sprintf("%s DOWN - %s (active; %s%s)", region, at("reason"), down, tail)
		}

	case "cluster_detail":
		region := at("listening")
		if nodes := at("nodes"); strings.HasPrefix(nodes, "0/0") {
			return "cluster", fmt.Sprintf("%s: no nodes in cluster map", region)
		} else {
			return "cluster", fmt.Sprintf("%s: %s nodes reachable", region, nodes)
		}
	case "cluster_nodes":
		if n := at("nodes"); n != "" {
			return "cluster", fmt.Sprintf("%s nodes: %s", at("region"), n)
		}
		return "cluster", fmt.Sprintf("%s nodes: (none reachable)", at("region"))
	case "cluster_map":
		return "cluster", fmt.Sprintf("Cluster map: %s", at("nodes"))
	case "cluster_map_change":
		verb := "joined"
		if at("action") == "removed" {
			verb = "left"
		}
		return "cluster", fmt.Sprintf("%s: node %s %s the cluster map", at("cluster"), at("host"), verb)

	case "failover_countdown_start":
		return "failover", fmt.Sprintf("Countdown started - switch to %s if %s stays DOWN %s", at("secondary"), at("active_region"), at("delay"))
	case "switch_required":
		return "failover", fmt.Sprintf("Switch required - %s DOWN", at("active_region"))
	case "switch_held":
		return "failover", fmt.Sprintf("Switch held - secondary not ready (%s)", at("secondary_status"))
	case "switch_skipped":
		return "failover", fmt.Sprintf("Switch skipped - %s", at("reason"))
	case "switched":
		return "failover", fmt.Sprintf("SWITCHED active cluster: %s -> %s", at("from"), at("to"))
	case "switch_noop":
		// Scoped to the ConfigMaps on purpose: the same call may still have rolled
		// Deployments (see roll_only), so this must not claim nothing happened.
		return "failover", fmt.Sprintf("Already on %s: ConfigMaps needed no change", at("active_region"))
	case "actuation_error":
		return "failover", fmt.Sprintf("Actuation failed: %s", at("err"))

	case "configmap_patch":
		return "actuator", fmt.Sprintf("Patching ConfigMap %s (ns=%s): %s -> %s",
			at("configmap"), at("namespace"), AddressList(at("from")), AddressList(at("to")))
	case "deployment_roll":
		return "actuator", fmt.Sprintf("Rolling deployment %s (ns=%s)", at("deployment"), at("namespace"))
	case "roll_only":
		return "actuator", fmt.Sprintf("ConfigMaps already on %s; rolled %s deployment(s) to pick it up",
			at("secondary"), at("rolled"))
	case "roll_skipped":
		return "actuator", fmt.Sprintf("Skipping rollout of %s (ns=%s): %s",
			at("deployment"), at("namespace"), at("reason"))

	case "webhook_target":
		return "webhook", fmt.Sprintf("Webhook: POST %s (auth: %s, verify: %s, timeout %s, retries %s)",
			at("url"), at("auth"), at("verify"), at("timeout"), at("retries"))
	case "webhook_called":
		return "webhook", fmt.Sprintf("Webhook called: %s -> %s (attempt %s)", at("url"), at("status"), at("attempt"))
	case "webhook_retry":
		return "webhook", fmt.Sprintf("Webhook attempt %s/%s failed (%s), retrying in %s",
			at("attempt"), at("attempts"), at("err"), at("wait"))
	case "webhook_failed":
		// This line reports only what pkg/notify knows: the delivery failed after
		// N attempts. Whether that held the switch latch open depends on the
		// OTHER actuator's outcome on this same tick, which pkg/notify cannot see
		// (see cmd/svchealthcheck/switch.go runSwitch). Do not resurrect a
		// construction-time "blocking" flag here: it can only state what was
		// enabled at startup, not what happened this tick.
		return "webhook", fmt.Sprintf("Webhook failed after %s attempts: %s", at("attempts"), at("err"))
	case "webhook_dropped":
		return "webhook", fmt.Sprintf("Switch already performed by the Kubernetes actuator (%s); webhook notification dropped: %s",
			at("active_region"), at("err"))
	case "webhook_dry_run":
		return "webhook", fmt.Sprintf("Webhook DRY RUN - would POST %s (%s -> %s)", at("url"), at("from"), at("to"))
	case "webhook_body":
		return "webhook", fmt.Sprintf("Webhook body: %s", at("body"))
	case "webhook_insecure":
		return "webhook", fmt.Sprintf("Webhook TLS verification DISABLED (insecure) for %s", at("url"))
	case "webhook_window_tight":
		return "webhook", fmt.Sprintf("Webhook budget tight: worst case %s (2x probe-timeout %s + webhook %s) >= 3x interval %s",
			at("worst_case"), at("probe_budget"), at("webhook_budget"), at("window"))
	case "mode_deprecated":
		return "observer", fmt.Sprintf("--mode is deprecated and goes away next release; use %s", at("replacement"))
	}

	// Unknown event: keep the name and dump fields so nothing is lost.
	var b strings.Builder
	b.WriteString(event)
	for k, v := range f {
		fmt.Fprintf(&b, " %s=%s", k, v.String())
	}
	return "observer", b.String()
}
