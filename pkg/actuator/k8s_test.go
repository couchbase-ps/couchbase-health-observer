package actuator

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

// seed builds a two-namespace world: the historical default/cb-conn + default/mock-app
// pair, plus an app-b namespace, so every test exercises the fan-out path.
func seed() *fake.Clientset {
	return fake.NewSimpleClientset(
		&corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Name: "cb-conn", Namespace: "default"},
			Data:       map[string]string{"connstring": "couchbase://region-a"},
		},
		&appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "mock-app", Namespace: "default"}},
		&corev1.ConfigMap{
			ObjectMeta: metav1.ObjectMeta{Name: "cb-conn", Namespace: "app-b"},
			Data:       map[string]string{"connstring": "couchbase://region-a"},
		},
		&appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "mock-app-b", Namespace: "app-b"}},
	)
}

// newActuator targets only the default namespace, matching the pre-fan-out tests.
func newActuator(cs *fake.Clientset, dryRun bool) *K8sActuator {
	return &K8sActuator{
		Client: cs,
		Cfg: Config{
			ConfigMaps:  []Ref{{Namespace: "default", Name: "cb-conn"}},
			ConfigKey:   "connstring",
			Deployments: []Ref{{Namespace: "default", Name: "mock-app"}},
			Secondary:   "couchbase://region-b",
			DryRun:      dryRun,
		},
		Now: func() string { return "2026-06-22T00:00:00Z" },
	}
}

// newMultiActuator targets both namespaces.
func newMultiActuator(cs *fake.Clientset) *K8sActuator {
	a := newActuator(cs, false)
	a.Cfg.ConfigMaps = []Ref{{Namespace: "default", Name: "cb-conn"}, {Namespace: "app-b", Name: "cb-conn"}}
	a.Cfg.Deployments = []Ref{{Namespace: "default", Name: "mock-app"}, {Namespace: "app-b", Name: "mock-app-b"}}
	return a
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
	if dep.Spec.Template.Annotations[AnnRestartedAt] != "2026-06-22T00:00:00Z" {
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

// TestSwitchRollsUnstampedDeploymentWhenConfigMapAlreadyOnSecondary isolates the
// annotation half of the deployment skip guard from the patchedNS half: the
// ConfigMap is already on the secondary before this call (so patchedNS stays
// false), but the Deployment carries no AnnSwitchedTo yet. It must still roll,
// because it may still be serving the primary connstring. If the guard were
// `if !patchedNS[ref.Namespace] { continue }` (dropping the annotation check),
// this Deployment would wrongly be skipped.
func TestSwitchRollsUnstampedDeploymentWhenConfigMapAlreadyOnSecondary(t *testing.T) {
	cs := seed()
	cm, _ := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	cm.Data["connstring"] = "couchbase://region-b"
	cs.CoreV1().ConfigMaps("default").Update(context.Background(), cm, metav1.UpdateOptions{})

	switched, err := newActuator(cs, false).Switch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if switched {
		t.Error("switched must be false: the configmap did not change in this call")
	}
	dep, _ := cs.AppsV1().Deployments("default").Get(context.Background(), "mock-app", metav1.GetOptions{})
	if dep.Spec.Template.Annotations[AnnSwitchedTo] != "couchbase://region-b" {
		t.Errorf("unstamped deployment must still roll when configmap already on secondary: %v", dep.Spec.Template.Annotations)
	}
}

// TestSwitchLogsRollOnly covers the state the caller cannot describe: every
// ConfigMap already held the secondary (nothing patched, so switched=false and the
// loop logs switch_noop) while the Deployments were unstamped and did roll. Only
// the actuator knows that count, so it must state the aggregate itself, or the
// operator reads a no-change line right under the roll lines.
func TestSwitchLogsRollOnly(t *testing.T) {
	cs := seed()
	for _, ns := range []string{"default", "app-b"} {
		cm, _ := cs.CoreV1().ConfigMaps(ns).Get(context.Background(), "cb-conn", metav1.GetOptions{})
		cm.Data["connstring"] = "couchbase://region-b"
		cs.CoreV1().ConfigMaps(ns).Update(context.Background(), cm, metav1.UpdateOptions{})
	}
	var buf bytes.Buffer
	a := newMultiActuator(cs)
	a.Log = slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo}))

	switched, err := a.Switch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if switched {
		t.Error("switched must be false: no configmap changed in this call")
	}
	out := buf.String()
	if !strings.Contains(out, "msg=roll_only") || !strings.Contains(out, "rolled=2") {
		t.Errorf("missing roll_only with the rolled count: %q", out)
	}
	if !strings.Contains(out, "secondary=couchbase://region-b") {
		t.Errorf("roll_only must name the secondary: %q", out)
	}
}

// TestSwitchDoesNotLogRollOnlyWhenConfigMapPatched pins the other half: a normal
// switch patches ConfigMaps, so the roll is not "roll only" and the caller's
// switched=true narrative already covers it.
func TestSwitchDoesNotLogRollOnlyWhenConfigMapPatched(t *testing.T) {
	cs := seed()
	var buf bytes.Buffer
	a := newMultiActuator(cs)
	a.Log = slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo}))

	switched, err := a.Switch(context.Background())
	if err != nil || !switched {
		t.Fatalf("switched=%v err=%v", switched, err)
	}
	if strings.Contains(buf.String(), "roll_only") {
		t.Errorf("roll_only must not appear when a configmap was patched: %q", buf.String())
	}
}

func TestSwitchLogsPatchAndRoll(t *testing.T) {
	cs := seed()
	var buf bytes.Buffer
	a := newActuator(cs, false)
	a.Log = slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if _, err := a.Switch(context.Background()); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	if !strings.Contains(out, "msg=configmap_patch") || !strings.Contains(out, "to=couchbase://region-b") {
		t.Errorf("missing configmap_patch: %q", out)
	}
	if !strings.Contains(out, "msg=deployment_roll") || !strings.Contains(out, "deployment=mock-app") {
		t.Errorf("missing deployment_roll: %q", out)
	}
}

func TestSwitchNoOpIsSilent(t *testing.T) {
	cs := seed()
	cm, _ := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	cm.Data["connstring"] = "couchbase://region-b"
	cs.CoreV1().ConfigMaps("default").Update(context.Background(), cm, metav1.UpdateOptions{})
	var buf bytes.Buffer
	a := newActuator(cs, false)
	a.Log = slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if _, err := a.Switch(context.Background()); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(buf.String(), "configmap_patch") {
		t.Errorf("no-op switch should not log a patch: %q", buf.String())
	}
}

func TestSwitchErrorsWhenConfigMapMissing(t *testing.T) {
	// The loop logs actuation_error when Switch returns a non-nil error; verify
	// the actuator surfaces one (rather than silently no-op'ing) on a k8s fault.
	cs := seed()
	a := newActuator(cs, false)
	a.Cfg.ConfigMaps = []Ref{{Namespace: "default", Name: "does-not-exist"}}
	switched, err := a.Switch(context.Background())
	if err == nil {
		t.Fatal("expected an error when the configmap is missing")
	}
	if switched {
		t.Error("switched must be false when actuation errors")
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

// TestSwitchDryRunAcrossNamespaces is the fan-out counterpart of TestSwitchDryRun:
// dry-run must report the intent yet write nothing in ANY namespace. Asserted on the
// clientset's recorded actions, not just the annotations, so a write that happens to
// set the same value cannot pass unnoticed.
func TestSwitchDryRunAcrossNamespaces(t *testing.T) {
	cs := seed()
	a := newMultiActuator(cs)
	a.Cfg.DryRun = true
	cs.ClearActions()

	switched, err := a.Switch(context.Background())
	if err != nil || !switched {
		t.Fatalf("dry-run should report intent: switched=%v err=%v", switched, err)
	}
	for _, act := range cs.Actions() {
		if act.GetVerb() != "get" {
			t.Errorf("dry-run wrote to the API: %s on %s", act.GetVerb(), act.GetResource().Resource)
		}
	}
	for _, ns := range []string{"default", "app-b"} {
		cm, _ := cs.CoreV1().ConfigMaps(ns).Get(context.Background(), "cb-conn", metav1.GetOptions{})
		if cm.Data["connstring"] != "couchbase://region-a" {
			t.Errorf("ns %s configmap mutated in dry-run: %q", ns, cm.Data["connstring"])
		}
	}
	for _, d := range []struct{ ns, name string }{{"default", "mock-app"}, {"app-b", "mock-app-b"}} {
		dep, _ := cs.AppsV1().Deployments(d.ns).Get(context.Background(), d.name, metav1.GetOptions{})
		if len(dep.Spec.Template.Annotations) != 0 {
			t.Errorf("%s/%s stamped in dry-run: %v", d.ns, d.name, dep.Spec.Template.Annotations)
		}
	}
}

func TestSwitchFansOutAcrossNamespaces(t *testing.T) {
	cs := seed()
	switched, err := newMultiActuator(cs).Switch(context.Background())
	if err != nil || !switched {
		t.Fatalf("switched=%v err=%v", switched, err)
	}
	for _, ns := range []string{"default", "app-b"} {
		cm, _ := cs.CoreV1().ConfigMaps(ns).Get(context.Background(), "cb-conn", metav1.GetOptions{})
		if cm.Data["connstring"] != "couchbase://region-b" {
			t.Errorf("ns %s connstring=%q, want region-b", ns, cm.Data["connstring"])
		}
	}
	for _, d := range []struct{ ns, name string }{{"default", "mock-app"}, {"app-b", "mock-app-b"}} {
		dep, _ := cs.AppsV1().Deployments(d.ns).Get(context.Background(), d.name, metav1.GetOptions{})
		ann := dep.Spec.Template.Annotations
		if ann[AnnSwitchedTo] != "couchbase://region-b" || ann[AnnRestartedAt] != "2026-06-22T00:00:00Z" {
			t.Errorf("%s/%s not rolled: %v", d.ns, d.name, ann)
		}
	}
}

func TestSwitchContinuesPastAFailedNamespace(t *testing.T) {
	cs := seed()
	a := newMultiActuator(cs)
	// app-b's ConfigMap does not exist: default must still be patched and rolled,
	// app-b's deployment must be skipped, and the call must report the error.
	a.Cfg.ConfigMaps = []Ref{{Namespace: "default", Name: "cb-conn"}, {Namespace: "app-b", Name: "missing"}}
	var buf bytes.Buffer
	a.Log = slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo}))

	switched, err := a.Switch(context.Background())
	if err == nil {
		t.Fatal("expected an error for the missing app-b configmap")
	}
	if switched {
		t.Error("switched must be false while a target is unconverged")
	}
	cm, _ := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	if cm.Data["connstring"] != "couchbase://region-b" {
		t.Errorf("healthy namespace not patched: %q", cm.Data["connstring"])
	}
	dep, _ := cs.AppsV1().Deployments("default").Get(context.Background(), "mock-app", metav1.GetOptions{})
	if dep.Spec.Template.Annotations[AnnSwitchedTo] != "couchbase://region-b" {
		t.Error("healthy namespace deployment not rolled")
	}
	depB, _ := cs.AppsV1().Deployments("app-b").Get(context.Background(), "mock-app-b", metav1.GetOptions{})
	if _, ok := depB.Spec.Template.Annotations[AnnSwitchedTo]; ok {
		t.Error("deployment in the failed namespace must not be stamped")
	}
	if !strings.Contains(buf.String(), "msg=roll_skipped") {
		t.Errorf("missing roll_skipped warning: %q", buf.String())
	}
}

func TestSwitchRetryDoesNotRollTwice(t *testing.T) {
	cs := seed()
	if _, err := newMultiActuator(cs).Switch(context.Background()); err != nil {
		t.Fatal(err)
	}
	cs.ClearActions()
	// Second call: everything already on the secondary, so nothing is updated.
	switched, err := newMultiActuator(cs).Switch(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if switched {
		t.Error("expected a no-op on the retry")
	}
	for _, a := range cs.Actions() {
		if a.GetVerb() == "update" {
			t.Fatalf("retry performed an update on %s", a.GetResource().Resource)
		}
	}
}

func TestSwitchRollsAgainWhenConfigMapWasRewound(t *testing.T) {
	// Mirrors kind e2e scenario C: the ConfigMap is put back on the primary by hand
	// while the deployment still carries switched-to=secondary. The next switch must
	// patch and roll again, so the app re-reads the secondary connstring.
	cs := seed()
	a := newMultiActuator(cs)
	if _, err := a.Switch(context.Background()); err != nil {
		t.Fatal(err)
	}
	cm, _ := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	cm.Data["connstring"] = "couchbase://region-a"
	if _, err := cs.CoreV1().ConfigMaps("default").Update(context.Background(), cm, metav1.UpdateOptions{}); err != nil {
		t.Fatal(err)
	}
	a.Now = func() string { return "2026-06-22T00:00:09Z" }

	switched, err := a.Switch(context.Background())
	if err != nil || !switched {
		t.Fatalf("switched=%v err=%v", switched, err)
	}
	dep, _ := cs.AppsV1().Deployments("default").Get(context.Background(), "mock-app", metav1.GetOptions{})
	if got := dep.Spec.Template.Annotations[AnnRestartedAt]; got != "2026-06-22T00:00:09Z" {
		t.Errorf("restartedAt=%q, want the second stamp (deployment must re-roll)", got)
	}
	depB, _ := cs.AppsV1().Deployments("app-b").Get(context.Background(), "mock-app-b", metav1.GetOptions{})
	if got := depB.Spec.Template.Annotations[AnnRestartedAt]; got != "2026-06-22T00:00:00Z" {
		t.Errorf("app-b restartedAt=%q, want the first stamp (nothing changed there)", got)
	}
}

// TestSwitchContinuesPastAMissingDeployment exercises the deployment loop's own
// best-effort path, distinct from TestSwitchContinuesPastAFailedNamespace (which
// exercises the configmap loop and the failedNS gate). Here both ConfigMaps patch
// cleanly; only default's Deployment ref is bad. app-b's Deployment must still roll.
func TestSwitchContinuesPastAMissingDeployment(t *testing.T) {
	cs := seed()
	a := newMultiActuator(cs)
	a.Cfg.Deployments = []Ref{{Namespace: "default", Name: "missing-app"}, {Namespace: "app-b", Name: "mock-app-b"}}

	switched, err := a.Switch(context.Background())
	if err == nil || !strings.Contains(err.Error(), "missing-app") {
		t.Fatalf("expected an error mentioning the missing deployment, got %v", err)
	}
	if switched {
		t.Error("switched must be false when a deployment target errors")
	}
	cm, _ := cs.CoreV1().ConfigMaps("default").Get(context.Background(), "cb-conn", metav1.GetOptions{})
	if cm.Data["connstring"] != "couchbase://region-b" {
		t.Errorf("default configmap not patched: %q", cm.Data["connstring"])
	}
	depB, _ := cs.AppsV1().Deployments("app-b").Get(context.Background(), "mock-app-b", metav1.GetOptions{})
	if depB.Spec.Template.Annotations[AnnSwitchedTo] != "couchbase://region-b" {
		t.Error("app-b deployment must still roll despite default's missing deployment")
	}
}

// TestSwitchRejectsEmptyConfigMapList guards the config edge where the target list
// parses to zero ConfigMaps (an unset Helm value, "--configmap="). Patching nothing
// and rolling every Deployment restarts every app, changes no connstring, and reports
// no error, which makes the observer latch as switched. So Switch must fail before it
// touches a single Deployment: no write action at all, and switched=false.
func TestSwitchRejectsEmptyConfigMapList(t *testing.T) {
	cs := seed()
	a := newActuator(cs, false)
	a.Cfg.ConfigMaps = nil
	cs.ClearActions()

	switched, err := a.Switch(context.Background())
	if err == nil {
		t.Error("expected an error when no connstring ConfigMap is configured")
	}
	if switched {
		t.Error("switched must be false when no ConfigMap is configured")
	}
	for _, act := range cs.Actions() {
		if act.GetVerb() != "get" {
			t.Errorf("no write must reach the API: got %s on %s", act.GetVerb(), act.GetResource().Resource)
		}
	}
	dep, _ := cs.AppsV1().Deployments("default").Get(context.Background(), "mock-app", metav1.GetOptions{})
	if len(dep.Spec.Template.Annotations) != 0 {
		t.Errorf("deployment must not be rolled: %v", dep.Spec.Template.Annotations)
	}
}
