package svchealth

import (
	"fmt"
	"sort"
)

// Compute rolls per-endpoint probes into per-service health and a global status.
// A service is DOWN if ANY of its endpoints is unreachable (an unreachable vbucket
// owner means operations to it fail); UP only if all its endpoints are reachable.
// Global is DOWN if any critical service is DOWN, else UP.
func Compute(probes []Probe, critical []string, checkedAt string) Report {
	type agg struct {
		reachable   int
		unreachable []string
	}
	byService := map[string]*agg{}
	for _, pr := range probes {
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

	global := "UP"
	reason := "all critical services reachable"
	for _, svc := range critical {
		sh, ok := services[svc]
		if !ok || sh.Status == "DOWN" {
			global = "DOWN"
			if !ok {
				reason = fmt.Sprintf("critical service %q not observed", svc)
			} else {
				reason = fmt.Sprintf("critical service %q has %d reachable endpoints", svc, sh.Reachable)
			}
			break
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
