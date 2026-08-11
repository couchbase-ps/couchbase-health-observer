package svchealth

import (
	"context"
	"testing"
	"time"

	"github.com/couchbase/gocb/v2"
)

func TestHostOnlyStripsSchemeAndPort(t *testing.T) {
	cases := map[string]string{
		"172.19.0.3:11210":       "172.19.0.3", // KV endpoint: host:port, no scheme
		"http://172.19.0.3:8093": "172.19.0.3", // query endpoint: scheme must be stripped too
		"https://node-a:18093":   "node-a",     // TLS query endpoint
		"172.19.0.3":             "172.19.0.3", // bare host
	}
	for in, want := range cases {
		if got := hostOnly(in); got != want {
			t.Errorf("hostOnly(%q) = %q, want %q", in, got, want)
		}
	}
}

// A cold start against a cluster that never bootstraps must not wedge the loop:
// Probe has to return within roughly its Timeout, not block indefinitely. Uses a
// TEST-NET-1 address (RFC 5737, non-routable) so no real cluster is needed.
func TestProbeBoundedAgainstUnreachableCluster(t *testing.T) {
	cluster, err := gocb.Connect("couchbase://192.0.2.1", gocb.ClusterOptions{
		Authenticator: gocb.PasswordAuthenticator{Username: "x", Password: "y"},
	})
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer cluster.Close(nil)
	b := cluster.Bucket("nonexistent")

	p := &GocbProber{Cluster: cluster, Bucket: b, Timeout: 500 * time.Millisecond}

	done := make(chan struct{})
	start := time.Now()
	go func() { _, _ = p.Probe(context.Background()); close(done) }()

	select {
	case <-done:
		if el := time.Since(start); el > 4*time.Second {
			t.Fatalf("Probe took %v against unreachable cluster, want bounded (~Timeout)", el)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("Probe did not return within 6s against unreachable cluster (unbounded ping)")
	}
}
