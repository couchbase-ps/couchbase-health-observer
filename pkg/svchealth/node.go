package svchealth

import (
	"fmt"
	"sort"
	"strings"
)

// NodeHealth is the per-node reachability rollup (SDK-honest: reachable vs
// unreachable services, never healthy vs failover).
type NodeHealth struct {
	Host        string
	Reachable   []string
	Unreachable []string
}

// ByNode pivots endpoint probes into a per-node view. Empty-host placeholder
// probes (services with no deployed node) are dropped. Hosts and the service
// lists inside each node are sorted for deterministic output.
func ByNode(probes []Probe) []NodeHealth {
	type agg struct{ reachable, unreachable []string }
	byHost := map[string]*agg{}
	for _, pr := range probes {
		if pr.Host == "" {
			continue
		}
		a := byHost[pr.Host]
		if a == nil {
			a = &agg{}
			byHost[pr.Host] = a
		}
		if pr.OK {
			a.reachable = append(a.reachable, pr.Service)
		} else {
			a.unreachable = append(a.unreachable, pr.Service)
		}
	}
	hosts := make([]string, 0, len(byHost))
	for h := range byHost {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)
	out := make([]NodeHealth, 0, len(hosts))
	for _, h := range hosts {
		a := byHost[h]
		sort.Strings(a.reachable)
		sort.Strings(a.unreachable)
		out = append(out, NodeHealth{Host: h, Reachable: a.reachable, Unreachable: a.unreachable})
	}
	return out
}

// NodeSummary counts nodes with no unreachable service (healthy) and the total.
func NodeSummary(nodes []NodeHealth) (healthy, total int) {
	for _, n := range nodes {
		if len(n.Unreachable) == 0 {
			healthy++
		}
	}
	return healthy, len(nodes)
}

// RenderNodes formats nodes as a single log-friendly line: each node marked
// UP (all services reachable, services listed) or DOWN (some service
// unreachable, the failing services listed), e.g.
//
//	172.19.0.3 UP(kv query), 172.19.0.4 DOWN(kv)
func RenderNodes(nodes []NodeHealth) string {
	parts := make([]string, 0, len(nodes))
	for _, n := range nodes {
		if len(n.Unreachable) == 0 {
			parts = append(parts, fmt.Sprintf("%s UP(%s)", n.Host, strings.Join(n.Reachable, " ")))
		} else {
			parts = append(parts, fmt.Sprintf("%s DOWN(%s)", n.Host, strings.Join(n.Unreachable, " ")))
		}
	}
	return strings.Join(parts, ", ")
}

// HostSet is the set of non-empty hosts present in a probe round.
func HostSet(probes []Probe) map[string]struct{} {
	set := map[string]struct{}{}
	for _, pr := range probes {
		if pr.Host != "" {
			set[pr.Host] = struct{}{}
		}
	}
	return set
}

// DiffHosts reports hosts added and removed between two rounds, both sorted.
func DiffHosts(prev, cur map[string]struct{}) (added, removed []string) {
	for h := range cur {
		if _, ok := prev[h]; !ok {
			added = append(added, h)
		}
	}
	for h := range prev {
		if _, ok := cur[h]; !ok {
			removed = append(removed, h)
		}
	}
	sort.Strings(added)
	sort.Strings(removed)
	return added, removed
}
