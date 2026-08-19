package actuator

import (
	"fmt"
	"sort"
	"strings"
)

// Ref is a namespace-qualified Kubernetes object name. The observer actuates
// several namespaces in one switch, so every target carries its own namespace
// instead of inheriting a single global one.
type Ref struct {
	Namespace string
	Name      string
}

func (r Ref) String() string { return r.Namespace + "/" + r.Name }

// ParseRefs turns a comma list of "ns/name" entries (or bare "name", which falls
// back to defaultNS) into refs. Called at flag/env parse time so a typo fails at
// startup instead of during an outage. Empty entries are dropped and duplicates
// removed, preserving order. Only "/" qualifies a namespace: ConfigMap and
// Deployment names may contain dots, so a dot form would mis-parse "app.config".
func ParseRefs(list, defaultNS string) ([]Ref, error) {
	var out []Ref
	seen := map[Ref]bool{}
	for _, entry := range strings.Split(list, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		ns, name := defaultNS, entry
		if i := strings.Index(entry, "/"); i >= 0 {
			ns, name = entry[:i], entry[i+1:]
		}
		if ns == "" || name == "" || strings.Contains(name, "/") {
			return nil, fmt.Errorf("invalid target %q: want ns/name (namespace %q)", entry, ns)
		}
		r := Ref{Namespace: ns, Name: name}
		if seen[r] {
			continue
		}
		seen[r] = true
		out = append(out, r)
	}
	return out, nil
}

// UnpairedNamespaces returns, sorted and deduped, the namespaces that hold at
// least one Deployment target and no ConfigMap target. A pod only reads
// ConfigMaps in its own namespace, so such a Deployment rolls once, gets stamped
// with the secondary, and is skipped on every later call, while the connstring it
// reads is never patched: nearly always a config error. Callers warn rather than
// exit, since an app can legitimately read a copy synced by other tooling.
func UnpairedNamespaces(configMaps, deployments []Ref) []string {
	hasConfigMap := map[string]bool{}
	for _, r := range configMaps {
		hasConfigMap[r.Namespace] = true
	}
	seen := map[string]bool{}
	var out []string
	for _, r := range deployments {
		if hasConfigMap[r.Namespace] || seen[r.Namespace] {
			continue
		}
		seen[r.Namespace] = true
		out = append(out, r.Namespace)
	}
	sort.Strings(out)
	return out
}

// ParseRefsRequired is ParseRefs for a list that must not be empty, i.e. the
// connstring ConfigMaps. Zero ConfigMaps is a config that can never converge: the
// switch would patch nothing yet still report success. Callers use it so that bad
// config fails at startup instead of mid-outage.
func ParseRefsRequired(list, defaultNS string) ([]Ref, error) {
	refs, err := ParseRefs(list, defaultNS)
	if err != nil {
		return nil, err
	}
	if len(refs) == 0 {
		return nil, fmt.Errorf("at least one target is required, got %q", list)
	}
	return refs, nil
}
