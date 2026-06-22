// Command svchealthcheck serves the SDK per-service health endpoint.
package main

import (
	"flag"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/couchbase/gocb/v2"
	"github.com/couchbaselabs/couchbase-health-observer/pkg/svchealth"
)

func main() {
	conn := flag.String("conn", "couchbase://localhost", "connection string")
	bucket := flag.String("bucket", "travel-sample", "bucket for KV ping")
	user := flag.String("user", "Administrator", "admin user")
	pass := flag.String("pass", "password", "admin pass")
	critical := flag.String("critical", "kv", "comma-separated critical services")
	addr := flag.String("addr", ":8080", "listen address")
	flag.Parse()

	cluster, err := gocb.Connect(*conn, gocb.ClusterOptions{
		Authenticator: gocb.PasswordAuthenticator{Username: *user, Password: *pass},
	})
	if err != nil {
		log.Fatal(err)
	}
	b := cluster.Bucket(*bucket)
	_ = b.WaitUntilReady(5*time.Second, nil)

	h := &svchealth.Handler{
		Prober:   &svchealth.GocbProber{Cluster: cluster, Bucket: b},
		Critical: strings.Split(*critical, ","),
	}
	mux := http.NewServeMux()
	mux.Handle("/health/couchbase", h)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	log.Printf("listening on %s (critical=%s)", *addr, *critical)
	log.Fatal(http.ListenAndServe(*addr, mux))
}
