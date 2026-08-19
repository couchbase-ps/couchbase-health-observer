package actuator

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// K8sActuator fans a region switch out across every namespace named in Cfg: it
// repoints each ConfigMaps entry to the secondary connstring and rolls each
// Deployments entry by stamping a pod-template annotation (the standard
// rollout-restart idiom). Idempotent per target, not globally: a ConfigMap
// already on the secondary is left alone, and a Deployment is left alone only
// when it already carries AnnSwitchedTo == Secondary AND its namespace's
// ConfigMap did not change in this call. An unstamped Deployment still rolls
// even when its ConfigMap was already on the secondary before this call
// started: it may still be serving the primary connstring, so rolling it is
// what makes the switch converge.
type K8sActuator struct {
	Client kubernetes.Interface
	Cfg    Config
	Now    func() string // injectable timestamp; defaults to RFC3339 now
	Log    *slog.Logger  // nil -> slog.Default()
}

func (a *K8sActuator) log() *slog.Logger {
	if a.Log != nil {
		return a.Log
	}
	return slog.Default()
}

// Switch patches every connstring ConfigMap and rolls every dependent Deployment,
// across as many namespaces as the config names. Best effort: a failing target
// does not stop the others, per-target errors come back joined, and the caller
// retries on its next tick. Outside dry-run, reports switched=true only when
// this call changed something and hit no error, so a partial fan-out never
// latches the state machine. In dry-run nothing is ever written, so switched
// reports only whether a ConfigMap is still pending, regardless of error: a
// harmless combination since a dry run makes no changes either way. An empty
// ConfigMaps list is a config error: it is reported before any Deployment is
// touched, so a caller that cannot retry (the Lambda) also fails loudly.
func (a *K8sActuator) Switch(ctx context.Context) (bool, error) {
	// No ConfigMap to patch means the switch can never converge: rolling the
	// Deployments would restart every app onto the unchanged connstring and report
	// success, latching the caller. Fail before touching anything.
	if len(a.Cfg.ConfigMaps) == 0 {
		return false, errors.New("no connstring configmap configured: nothing to switch")
	}
	p := a.patchConfigMaps(ctx)
	if a.Cfg.DryRun {
		return p.pending > 0, errors.Join(p.errs...)
	}
	now := a.Now
	if now == nil {
		now = func() string { return time.Now().UTC().Format(time.RFC3339) }
	}
	rolled, rollErrs := a.rollDeployments(ctx, p, now())

	// Patched nothing yet rolled something: the caller reports switched=false and
	// logs its no-op line, which would otherwise read as "no action" directly under
	// the roll lines. Only this call knows the count, so state the aggregate here.
	if p.pending == 0 && rolled > 0 {
		a.log().Info("roll_only", "rolled", rolled, "secondary", a.Cfg.Secondary)
	}

	err := errors.Join(append(p.errs, rollErrs...)...)
	return err == nil && p.pending > 0, err
}

// patchLedger is what the roll phase needs to know about the patch phase. It is
// passed explicitly so neither phase reads the other's locals.
type patchLedger struct {
	patchedNS map[string]bool // namespaces whose ConfigMap changed in this call
	failedNS  map[string]bool // namespaces holding a ConfigMap we could not converge
	pending   int             // ConfigMaps that were not yet on the secondary
	errs      []error
}

// patchConfigMaps repoints every connstring ConfigMap to the secondary, best
// effort, and reports the ledger the roll phase gates on. Writes nothing in
// dry-run, yet still counts what it would have changed.
func (a *K8sActuator) patchConfigMaps(ctx context.Context) patchLedger {
	led := patchLedger{patchedNS: map[string]bool{}, failedNS: map[string]bool{}}
	for _, ref := range a.Cfg.ConfigMaps {
		cm, err := a.Client.CoreV1().ConfigMaps(ref.Namespace).Get(ctx, ref.Name, metav1.GetOptions{})
		if err != nil {
			led.errs = append(led.errs, fmt.Errorf("get configmap %s: %w", ref, err))
			led.failedNS[ref.Namespace] = true
			continue
		}
		if cm.Data[a.Cfg.ConfigKey] == a.Cfg.Secondary {
			continue // already switched
		}
		led.pending++
		if a.Cfg.DryRun {
			continue // would switch, but make no changes
		}
		if cm.Data == nil {
			cm.Data = map[string]string{}
		}
		from := cm.Data[a.Cfg.ConfigKey]
		cm.Data[a.Cfg.ConfigKey] = a.Cfg.Secondary
		if _, err := a.Client.CoreV1().ConfigMaps(ref.Namespace).Update(ctx, cm, metav1.UpdateOptions{}); err != nil {
			led.errs = append(led.errs, fmt.Errorf("update configmap %s: %w", ref, err))
			led.failedNS[ref.Namespace] = true
			continue
		}
		led.patchedNS[ref.Namespace] = true
		a.log().Info("configmap_patch",
			"configmap", ref.Name, "namespace", ref.Namespace,
			"key", a.Cfg.ConfigKey, "from", from, "to", a.Cfg.Secondary)
	}
	return led
}

// rollDeployments stamps stamp on every Deployment that needs to re-read its
// connstring and reports how many it rolled, best effort. led gates the skips, so
// a namespace whose ConfigMap is stuck keeps its Deployment unstamped.
func (a *K8sActuator) rollDeployments(ctx context.Context, led patchLedger, stamp string) (int, []error) {
	var errs []error
	rolled := 0
	for _, ref := range a.Cfg.Deployments {
		// A Deployment whose own ConfigMap is stuck on the primary must not be
		// stamped: it would look rolled and never re-roll once that ConfigMap converges.
		if led.failedNS[ref.Namespace] {
			a.log().Warn("roll_skipped", "deployment", ref.Name,
				"namespace", ref.Namespace, "reason", "configmap_failed")
			continue
		}
		dep, err := a.Client.AppsV1().Deployments(ref.Namespace).Get(ctx, ref.Name, metav1.GetOptions{})
		if err != nil {
			errs = append(errs, fmt.Errorf("get deployment %s: %w", ref, err))
			continue
		}
		// Skip only when this namespace saw no patch in this call AND the Deployment
		// already carries the secondary: that is the retry case, where re-rolling
		// would restart a healthy app for nothing.
		if !led.patchedNS[ref.Namespace] && dep.Spec.Template.Annotations[AnnSwitchedTo] == a.Cfg.Secondary {
			continue
		}
		if dep.Spec.Template.Annotations == nil {
			dep.Spec.Template.Annotations = map[string]string{}
		}
		dep.Spec.Template.Annotations[AnnSwitchedTo] = a.Cfg.Secondary
		dep.Spec.Template.Annotations[AnnRestartedAt] = stamp
		if _, err := a.Client.AppsV1().Deployments(ref.Namespace).Update(ctx, dep, metav1.UpdateOptions{}); err != nil {
			errs = append(errs, fmt.Errorf("roll deployment %s: %w", ref, err))
			continue
		}
		rolled++
		a.log().Info("deployment_roll", "deployment", ref.Name, "namespace", ref.Namespace)
	}
	return rolled, errs
}
