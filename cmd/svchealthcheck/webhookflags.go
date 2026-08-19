package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/couchbaselabs/couchbase-health-observer/pkg/notify"
)

// stringList collects a repeatable flag, e.g. --webhook-header used twice.
type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ", ") }

func (s *stringList) Set(v string) error {
	*s = append(*s, v)
	return nil
}

// resolveCred returns the flag value, or the environment variable when the flag
// is empty. The env path exists so a Kubernetes Secret can inject the credential
// without a plaintext password sitting in the Deployment args.
func resolveCred(flagVal, envKey string) string {
	if flagVal != "" {
		return flagVal
	}
	return os.Getenv(envKey)
}

// resolveHeaders parses the repeatable --webhook-header flag, falling back to a
// newline-separated environment variable when no flag was given. A flag replaces
// the environment value outright rather than merging with it, so the effective
// header set is always visible in one place.
func resolveHeaders(flagVals []string, envKey string) ([]notify.Header, error) {
	raw := flagVals
	if len(raw) == 0 {
		for _, line := range strings.Split(os.Getenv(envKey), "\n") {
			if strings.TrimSpace(line) != "" {
				raw = append(raw, line)
			}
		}
	}
	var out []notify.Header
	for _, r := range raw {
		h, err := notify.ParseHeader(r)
		if err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, nil
}

// authSummary describes the configured auth for the startup line, without ever
// revealing a credential.
func authSummary(user string, headers []notify.Header) string {
	unit := "headers"
	if len(headers) == 1 {
		unit = "header"
	}
	switch {
	case user == "" && len(headers) == 0:
		return "none"
	case user != "" && len(headers) == 0:
		return "basic"
	case user == "":
		return fmt.Sprintf("%d %s", len(headers), unit)
	default:
		return fmt.Sprintf("basic+%d %s", len(headers), unit)
	}
}

// webhookWorstCase is the longest a delivery can take: every attempt timing out,
// plus the backoff between them. It must stay under the 3*interval liveness
// window or a webhook against a dead endpoint starves the heartbeat and the pod
// gets restarted during the outage it is supposed to act on.
func webhookWorstCase(timeout time.Duration, retries int) time.Duration {
	total := time.Duration(retries+1) * timeout
	for attempt := 1; attempt <= retries; attempt++ {
		total += notify.DefaultBackoff(attempt)
	}
	return total
}
