package main

import (
	"testing"
	"time"

	"github.com/couchbaselabs/couchbase-health-observer/pkg/notify"
)

func TestResolveCredPrefersFlag(t *testing.T) {
	t.Setenv("WEBHOOK_PASS", "from-env")
	if got := resolveCred("from-flag", "WEBHOOK_PASS"); got != "from-flag" {
		t.Errorf("resolveCred = %q, want the flag value to win", got)
	}
	if got := resolveCred("", "WEBHOOK_PASS"); got != "from-env" {
		t.Errorf("resolveCred = %q, want the env value when the flag is empty", got)
	}
	if got := resolveCred("", "WEBHOOK_UNSET_FOR_TEST"); got != "" {
		t.Errorf("resolveCred = %q, want empty when neither is set", got)
	}
}

func TestResolveHeaders(t *testing.T) {
	t.Setenv("WEBHOOK_HEADER", "PRIVATE-TOKEN: glpat-env\nX-Source: observer")

	// No flags: the env supplies both headers, one per line.
	got, err := resolveHeaders(nil, "WEBHOOK_HEADER")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Key != "PRIVATE-TOKEN" || got[0].Value != "glpat-env" || got[1].Key != "X-Source" {
		t.Fatalf("resolveHeaders from env = %+v, want both headers parsed", got)
	}

	// Any flag replaces the env value outright; it does not merge.
	got, err = resolveHeaders([]string{"X-Only: 1"}, "WEBHOOK_HEADER")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Key != "X-Only" {
		t.Fatalf("resolveHeaders with a flag = %+v, want only the flag header", got)
	}

	if _, err := resolveHeaders([]string{"broken"}, "WEBHOOK_HEADER"); err == nil {
		t.Error("resolveHeaders with a malformed flag = nil error, want an error")
	}
}

func TestAuthSummary(t *testing.T) {
	two := []notify.Header{{Key: "A"}, {Key: "B"}}
	cases := []struct {
		user    string
		headers []notify.Header
		want    string
	}{
		{"", nil, "none"},
		{"obs", nil, "basic"},
		{"", two, "2 headers"},
		{"obs", two, "basic+2 headers"},
		{"obs", []notify.Header{{Key: "A"}}, "basic+1 header"},
	}
	for _, c := range cases {
		if got := authSummary(c.user, c.headers); got != c.want {
			t.Errorf("authSummary(%q, %d headers) = %q, want %q", c.user, len(c.headers), got, c.want)
		}
	}
}

func TestWebhookWorstCase(t *testing.T) {
	// 3 attempts of 3s, plus 1s + 2s of backoff between them.
	if got := webhookWorstCase(3*time.Second, 2); got != 12*time.Second {
		t.Errorf("webhookWorstCase(3s, 2) = %s, want 12s", got)
	}
	if got := webhookWorstCase(5*time.Second, 2); got != 18*time.Second {
		t.Errorf("webhookWorstCase(5s, 2) = %s, want 18s", got)
	}
	if got := webhookWorstCase(3*time.Second, 0); got != 3*time.Second {
		t.Errorf("webhookWorstCase(3s, 0) = %s, want 3s", got)
	}
}

func TestStringListIsRepeatable(t *testing.T) {
	var l stringList
	if err := l.Set("A: 1"); err != nil {
		t.Fatal(err)
	}
	if err := l.Set("B: 2"); err != nil {
		t.Fatal(err)
	}
	if len(l) != 2 || l[1] != "B: 2" {
		t.Fatalf("stringList = %v, want both values appended", l)
	}
}
