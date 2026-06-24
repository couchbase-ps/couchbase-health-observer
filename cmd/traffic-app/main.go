// Command traffic-app is a small Couchbase workload for the failover demo. It connects to
// the cluster named by --conn (the value the switch Lambda flips in the cb-conn ConfigMap)
// and, in a loop, upserts and reads a document, logging each operation and the connection
// string it is using. During a region switch you can watch operations fail on the dead
// cluster and resume against the secondary once the app is rolled onto the new connstring.
package main

import (
	"flag"
	"log"
	"os"
	"time"

	"github.com/couchbase/gocb/v2"
)

func main() {
	conn := flag.String("conn", env("CONNSTRING", "couchbase://localhost"), "connection string")
	bucket := flag.String("bucket", env("BUCKET", "observer"), "bucket for KV ops")
	user := flag.String("user", env("CB_USER", "Administrator"), "admin user")
	pass := flag.String("pass", env("CB_PASS", "password"), "admin pass")
	interval := flag.Duration("interval", 1*time.Second, "op interval")
	flag.Parse()

	log.Printf("traffic-app starting: conn=%s bucket=%s", *conn, *bucket)
	col := connect(*conn, *bucket, *user, *pass)

	key := "demo::traffic"
	for n := 1; ; n++ {
		doc := map[string]any{"n": n, "ts": time.Now().UTC().Format(time.RFC3339Nano), "conn": *conn}
		if _, err := col.Upsert(key, doc, &gocb.UpsertOptions{Timeout: 3 * time.Second}); err != nil {
			log.Printf("op=%d conn=%s result=ERR upsert: %v", n, *conn, err)
		} else if _, err := col.Get(key, &gocb.GetOptions{Timeout: 3 * time.Second}); err != nil {
			log.Printf("op=%d conn=%s result=ERR get: %v", n, *conn, err)
		} else {
			log.Printf("op=%d conn=%s result=OK", n, *conn)
		}
		time.Sleep(*interval)
	}
}

// connect retries until the bucket is reachable, so a pod that starts while its target
// cluster is still coming up (or right after a switch) waits instead of crashing.
func connect(conn, bucket, user, pass string) *gocb.Collection {
	for {
		cluster, err := gocb.Connect(conn, gocb.ClusterOptions{
			Authenticator: gocb.PasswordAuthenticator{Username: user, Password: pass},
		})
		if err != nil {
			log.Printf("connect %s failed, retrying: %v", conn, err)
			time.Sleep(2 * time.Second)
			continue
		}
		b := cluster.Bucket(bucket)
		if err := b.WaitUntilReady(10*time.Second, nil); err != nil {
			log.Printf("bucket %s not ready on %s, retrying: %v", bucket, conn, err)
			_ = cluster.Close(nil)
			time.Sleep(2 * time.Second)
			continue
		}
		log.Printf("connected to %s (bucket %s)", conn, bucket)
		return b.DefaultCollection()
	}
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
