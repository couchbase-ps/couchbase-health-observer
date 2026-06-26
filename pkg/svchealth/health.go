package svchealth

import (
	"fmt"
	"sort"
)

// Compute rolls per-endpoint probes into per-service health and a global status.
// A service is DOWN if ANY of its endpoints is unreachable (an unreachable vbucket
// owner means operations to it fail); UP only if all its endpoints are reachable.
// Global status:
//   - DOWN     if any critical service is DOWN (or not observed)
//   - DEGRADED if all critical services are UP but a non-critical service is DOWN
//   - UP       if every observed service is UP
func Compute(probes []Probe, critical []string, checkedAt string) Report {
	type agg struct {
		reachable   int
		unreachable []string
	}
	byService := map[string]*agg{}
	for _, pr := range probes {
		if pr.Host == "" {
			continue // placeholder for a service with no deployed node; omit it
		}
		a := byService[pr.Service]
		if a == nil {
			a = &agg{}
			byService[pr.Service] = a
		}
		if pr.OK {
			a.reachable++
		} else {
			a.unreachable = append(a.unreachable, pr.Host)
		}
	}

	services := map[string]ServiceHealth{}
	for svc, a := range byService {
		sort.Strings(a.unreachable)
		status := "UP"
		if len(a.unreachable) > 0 || a.reachable == 0 {
			status = "DOWN"
		}
		services[svc] = ServiceHealth{Status: status, Reachable: a.reachable, Unreachable: a.unreachable}
	}

	criticalSet := make(map[string]bool, len(critical))
	for _, svc := range critical {
		criticalSet[svc] = true
	}

	// Stable service ordering so the chosen reason is deterministic.
	names := make([]string, 0, len(services))
	for name := range services {
		names = append(names, name)
	}
	sort.Strings(names)

	global := "UP"
	reason := "all critical services reachable"

	// A critical service down (or unobserved) is a hard DOWN.
	for _, svc := range critical {
		sh, ok := services[svc]
		if !ok {
			global = "DOWN"
			reason = fmt.Sprintf("critical service %q not observed", svc)
			break
		}
		if sh.Status == "DOWN" {
			global = "DOWN"
			reason = fmt.Sprintf("critical service %q has %d non reachable endpoint(s)", svc, len(sh.Unreachable))
			break
		}
	}

	// All critical services healthy: a non-critical service being down degrades.
	if global == "UP" {
		for _, name := range names {
			if criticalSet[name] {
				continue
			}
			if services[name].Status == "DOWN" {
				global = "DEGRADED"
				reason = fmt.Sprintf("non-critical service %q has %d non reachable endpoint(s)", name, len(services[name].Unreachable))
				break
			}
		}
	}

	return Report{
		Status:    global,
		Critical:  critical,
		Services:  services,
		Reason:    reason,
		CheckedAt: checkedAt,
	}
}
