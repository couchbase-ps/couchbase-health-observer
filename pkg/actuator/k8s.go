package actuator

import (
	"context"
	"fmt"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// K8sActuator repoints the connection-string ConfigMap to the secondary cluster
// and rolls the dependent Deployments by stamping a pod-template annotation (the
// standard rollout-restart idiom). Idempotent: a no-op when already on secondary.
type K8sActuator struct {
	Client kubernetes.Interface
	Cfg    Config
	Now    func() string // injectable timestamp; defaults to RFC3339 now
}

func (a *K8sActuator) Switch(ctx context.Context) (bool, error) {
	now := a.Now
	if now == nil {
		now = func() string { return time.Now().UTC().Format(time.RFC3339) }
	}
	cm, err := a.Client.CoreV1().ConfigMaps(a.Cfg.Namespace).Get(ctx, a.Cfg.ConfigMap, metav1.GetOptions{})
	if err != nil {
		return false, fmt.Errorf("get configmap: %w", err)
	}
	if cm.Data[a.Cfg.ConfigKey] == a.Cfg.Secondary {
		return false, nil // already switched
	}
	if a.Cfg.DryRun {
		return true, nil // would switch, but make no changes
	}
	if cm.Data == nil {
		cm.Data = map[string]string{}
	}
	cm.Data[a.Cfg.ConfigKey] = a.Cfg.Secondary
	if _, err := a.Client.CoreV1().ConfigMaps(a.Cfg.Namespace).Update(ctx, cm, metav1.UpdateOptions{}); err != nil {
		return false, fmt.Errorf("update configmap: %w", err)
	}
	stamp := now()
	for _, name := range a.Cfg.Deployments {
		dep, err := a.Client.AppsV1().Deployments(a.Cfg.Namespace).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return false, fmt.Errorf("get deployment %s: %w", name, err)
		}
		if dep.Spec.Template.Annotations == nil {
			dep.Spec.Template.Annotations = map[string]string{}
		}
		dep.Spec.Template.Annotations["observer/restartedAt"] = stamp
		if _, err := a.Client.AppsV1().Deployments(a.Cfg.Namespace).Update(ctx, dep, metav1.UpdateOptions{}); err != nil {
			return false, fmt.Errorf("roll deployment %s: %w", name, err)
		}
	}
	return true, nil
}
