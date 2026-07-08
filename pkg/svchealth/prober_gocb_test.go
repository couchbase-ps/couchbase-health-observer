package svchealth

import (
	"context"
	"testing"
	"time"

	"github.com/couchbase/gocb/v2"
)

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
