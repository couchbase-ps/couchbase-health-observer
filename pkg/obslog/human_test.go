package obslog

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"
)

// helper: render one event through the human handler and return the line.
func humanLine(t *testing.T, level slog.Level, event string, args ...any) string {
	t.Helper()
	var buf bytes.Buffer
	NewHuman(&buf, LevelTrace).Log(context.Background(), level, event, args...)
	return buf.String()
}

// TestHumanCatalog renders every event through the real handler and asserts its
// exact human line — especially the events the kind e2e never triggers
// (DEGRADED, cluster_map_change, switch_held/skipped/noop, actuation_error,
// secondary_connect_failed, liveness_window_tight). This is the golden record of
// how each line looks. Run `go test ./pkg/obslog/ -run TestHumanCatalog -v` to
// print them.
func TestHumanCatalog(t *testing.T) {
	cases := []struct {
		name  string
		level slog.Level
		event string
		args  []any
		comp  string
		want  string // message text (after the "LEVEL component" prefix)
	}{
		{"health DEGRADED", slog.LevelInfo, "health",
			[]any{"status", "DEGRADED", "reason", `non-critical service "query" has 2/2 endpoint(s) unreachable`, "switch_required", false, "switched", false, "active_region", "primary", "sustained_down_s", 0.0},
			"health", `primary DEGRADED - non-critical service "query" has 2/2 endpoint(s) unreachable (active)`},
		{"cluster_map_change removed", slog.LevelWarn, "cluster_map_change",
			[]any{"action", "removed", "host", "172.19.0.3", "cluster", "region-a"},
			"cluster", "region-a: node 172.19.0.3 left the cluster map"},
		{"cluster_map_change added", slog.LevelInfo, "cluster_map_change",
			[]any{"action", "added", "host", "172.19.0.5", "cluster", "region-a"},
			"cluster", "region-a: node 172.19.0.5 joined the cluster map"},
		{"cluster_map", slog.LevelInfo, "cluster_map",
			[]any{"nodes", "172.19.0.3 172.19.0.4"},
			"cluster", "Cluster map: 172.19.0.3 172.19.0.4"},
		{"switch_noop", slog.LevelInfo, "switch_noop",
			[]any{"active_region", "secondary (10.20.30.40)"},
			"failover", "Already on secondary (10.20.30.40), no action"},
		{"switch_held", slog.LevelWarn, "switch_held",
			[]any{"reason", "secondary_not_ready", "secondary_status", "DOWN"},
			"failover", "Switch held - secondary not ready (DOWN)"},
		{"switch_skipped", slog.LevelWarn, "switch_skipped",
			[]any{"reason", "secondary_conn_empty"},
			"failover", "Switch skipped - secondary_conn_empty"},
		{"actuation_error", slog.LevelError, "actuation_error",
			[]any{"err", "get deployment mock-app: not found"},
			"failover", "Actuation failed: get deployment mock-app: not found"},
		{"secondary_connect_failed", slog.LevelWarn, "secondary_connect_failed",
			[]any{"err", "no such host"},
			"observer", "Secondary connect failed (treated as DOWN): no such host"},
		{"liveness_window_tight", slog.LevelWarn, "liveness_window_tight",
			[]any{"twice_probe_timeout", "10s", "window", "6s"},
			"observer", "Liveness window tight: 2x probe-timeout 10s >= 3x interval 6s"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			line := humanLine(t, c.level, c.event, c.args...)
			if !strings.Contains(line, levelLabel(c.level)) || !strings.Contains(line, c.comp) || !strings.Contains(line, c.want) {
				t.Errorf("%s =\n  %q\nwant level %s + component %q + %q", c.event, line, levelLabel(c.level), c.comp, c.want)
			}
			t.Logf("%s", strings.TrimRight(line, "\n"))
		})
	}
}

func TestHumanFormatShape(t *testing.T) {
	line := humanLine(t, slog.LevelInfo, "startup", "mode", "active", "critical", "kv", "addr", ":8080")
	// HH:mm:ss.SSS LEVEL component message — no key=value noise, no time=/level=/msg=.
	if strings.Contains(line, "msg=") || strings.Contains(line, "level=") || strings.Contains(line, "time=") {
		t.Errorf("human line still has slog key=val labels: %q", line)
	}
	for _, want := range []string{"INFO", "observer", "Started in active mode on :8080 (critical: kv)"} {
		if !strings.Contains(line, want) {
			t.Errorf("startup line missing %q: %q", want, line)
		}
	}
}

func TestHumanHealthDown(t *testing.T) {
	line := humanLine(t, slog.LevelInfo, "health",
		"status", "DOWN", "reason", `critical service "kv" has 1/3 endpoint(s) unreachable`,
		"switch_required", false, "switched", false, "active_region", "primary", "sustained_down_s", 0.0)
	want := `primary DOWN - critical service "kv" has 1/3 endpoint(s) unreachable (active; no switch yet)`
	if !strings.Contains(line, "health") || !strings.Contains(line, want) {
		t.Errorf("health DOWN line = %q, want component health + %q", line, want)
	}
}

func TestHumanHealthUp(t *testing.T) {
	line := humanLine(t, slog.LevelInfo, "health",
		"status", "UP", "reason", "all critical services reachable",
		"switch_required", false, "switched", false, "active_region", "primary", "sustained_down_s", 0.0)
	if !strings.Contains(line, "primary UP - all critical services reachable") {
		t.Errorf("health UP line wrong: %q", line)
	}
}

func TestHumanHealthDownShowsSustainedAndSwitched(t *testing.T) {
	line := humanLine(t, slog.LevelDebug, "health",
		"status", "DOWN", "reason", "critical service \"kv\" has 2/2 endpoint(s) unreachable",
		"switch_required", true, "switched", true, "active_region", "secondary", "sustained_down_s", 12.7)
	if !strings.Contains(line, "secondary DOWN") || !strings.Contains(line, "down 13s; already switched, holding") {
		t.Errorf("expected sustained-down + switched tail, got: %q", line)
	}
}

func TestHumanSwitchAndActuatorEvents(t *testing.T) {
	cases := []struct {
		event string
		args  []any
		comp  string
		want  string
	}{
		{"clusters", []any{"primary", "10.0.1.5, 10.0.1.6", "secondary", "10.20.30.40"},
			"observer", "Clusters: primary=10.0.1.5, 10.0.1.6, secondary=10.20.30.40"},
		{"switched", []any{"from", "primary (10.0.1.5, 10.0.1.6)", "to", "secondary (10.20.30.40)", "secondary_conn", "couchbase://10.20.30.40", "primary_nodes", "10.0.1.5"},
			"failover", "SWITCHED active cluster: primary (10.0.1.5, 10.0.1.6) -> secondary (10.20.30.40)"},
		{"configmap_patch", []any{"configmap", "cb-conn", "namespace", "default", "key", "connstring", "from", "couchbase://10.0.1.5:11210,10.0.1.6:11210", "to", "couchbase://10.20.30.40:11210"},
			"actuator", "Patching ConfigMap cb-conn (ns=default): 10.0.1.5, 10.0.1.6 -> 10.20.30.40"},
		{"deployment_roll", []any{"deployment", "mock-app", "namespace", "default"},
			"actuator", "Rolling deployment mock-app (ns=default)"},
		{"adopt_switched", []any{"secondary", "secondary (10.20.30.40)"},
			"observer", "Adopting already-switched state: now on secondary (10.20.30.40)"},
		{"cluster_map_change", []any{"action", "removed", "host", "172.19.0.3", "cluster", "primary"},
			"cluster", "primary: node 172.19.0.3 left the cluster map"},
		{"failover_countdown_start", []any{"delay", "30s", "secondary", "secondary (10.20.30.40)", "active_region", "primary (10.0.1.5, 10.0.1.6)"},
			"failover", "Countdown started - switch to secondary (10.20.30.40) if primary (10.0.1.5, 10.0.1.6) stays DOWN 30s"},
	}
	for _, c := range cases {
		line := humanLine(t, slog.LevelInfo, c.event, c.args...)
		if !strings.Contains(line, c.comp) || !strings.Contains(line, c.want) {
			t.Errorf("event %q line = %q, want component %q + %q", c.event, line, c.comp, c.want)
		}
	}
}

func TestHumanClusterNodesIsTrace(t *testing.T) {
	line := humanLine(t, LevelTrace, "cluster_nodes", "region", "primary", "nodes", "172.19.0.3 UP(kv query), 172.19.0.4 DOWN(kv)")
	if !strings.Contains(line, "TRACE") || !strings.Contains(line, "cluster") ||
		!strings.Contains(line, "primary nodes: 172.19.0.3 UP(kv query), 172.19.0.4 DOWN(kv)") {
		t.Errorf("cluster_nodes TRACE line wrong: %q", line)
	}
	empty := humanLine(t, LevelTrace, "cluster_nodes", "region", "secondary", "nodes", "")
	if !strings.Contains(empty, "secondary nodes: (none reachable)") {
		t.Errorf("empty cluster_nodes line wrong: %q", empty)
	}
}

func TestHumanLevelGating(t *testing.T) {
	var buf bytes.Buffer
	l := NewHuman(&buf, slog.LevelInfo)
	l.Debug("cluster_detail", "listening", "region-a", "nodes", "2/2", "namespace", "default")
	if buf.Len() != 0 {
		t.Errorf("debug event should be gated at info level, got: %q", buf.String())
	}
}

func TestHumanUnknownEventNotDropped(t *testing.T) {
	line := humanLine(t, slog.LevelInfo, "surprise_event", "k", "v")
	if !strings.Contains(line, "surprise_event") || !strings.Contains(line, "k=v") {
		t.Errorf("unknown event should keep name + fields, got: %q", line)
	}
}

func TestClusterLabel(t *testing.T) {
	cases := map[string]string{
		"couchbase://region-a-srv.region-a.svc":  "region-a",
		"couchbases://region-b-srv.region-b.svc": "region-b",
		"couchbase://10.0.1.5":                   "10.0.1.5", // IPv4 (Emirates): keep the address
		"couchbase://10.0.1.5:11210":             "10.0.1.5", // strip the port
		"couchbase://10.0.1.5,10.0.1.6,10.0.1.7": "10.0.1.5", // multi-host: first host
		"couchbases://192.168.10.20:11207":       "192.168.10.20",
		"127.0.0.1:9999":                         "127.0.0.1", // no scheme
		"":                                       "none",
	}
	for in, want := range cases {
		if got := ClusterLabel(in); got != want {
			t.Errorf("ClusterLabel(%q) = %q, want %q", in, got, want)
		}
	}
}
