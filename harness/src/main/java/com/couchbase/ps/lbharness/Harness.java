package com.couchbase.ps.lbharness;

import com.couchbase.client.java.Bucket;
import com.couchbase.client.java.Cluster;
import com.couchbase.client.java.ClusterOptions;
import com.couchbase.client.java.Collection;
import com.couchbase.client.java.json.JsonObject;
import com.couchbase.client.java.kv.GetOptions;
import com.couchbase.client.java.kv.UpsertOptions;
import com.couchbase.client.java.query.QueryOptions;
import com.couchbase.client.java.query.QueryResult;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.util.List;

/**
 * Availability harness for the CNG load-balancer test.
 *
 * Drives KV and SQL++ through whatever endpoint CB_CONN names, and records one
 * CSV line per operation. It never throws out of the loop: a failure is the
 * measurement, not an error.
 *
 * The region column comes from a marker document written into each cluster by
 * init-cluster.sh, so which cluster served an operation is observed rather than
 * inferred. Availability is the only assertion: with no XDCR the two clusters
 * hold different data, so document content proves nothing.
 */
public final class Harness {

  private static String env(String k, String dflt) {
    String v = System.getenv(k);
    return (v == null || v.isBlank()) ? dflt : v;
  }

  public static void main(String[] args) throws Exception {
    String conn = env("CB_CONN", "couchbase2://cng-lb");
    String user = env("CB_USER", "Administrator");
    String pass = env("CB_PASS", "password");
    String bucketName = env("CB_BUCKET", "lbtest");
    String tlsCa = env("TLS_CA", "");
    int opsPerSec = Integer.parseInt(env("OPS_PER_SEC", "20"));
    int queryPerSec = Integer.parseInt(env("QUERY_PER_SEC", "1"));
    int runSeconds = Integer.parseInt(env("RUN_SECONDS", "60"));
    int idleAtSecond = Integer.parseInt(env("IDLE_AT_SECOND", "0"));
    int idleSeconds = Integer.parseInt(env("IDLE_SECONDS", "0"));
    Path out = Paths.get(env("OUT_CSV", "/out/harness.csv"));

    Files.createDirectories(out.getParent());

    ClusterOptions opts = ClusterOptions.clusterOptions(user, pass);
    if (!tlsCa.isBlank()) {
      Path ca = Paths.get(tlsCa);
      opts = opts.environment(env -> env.securityConfig(
          sec -> sec.enableTls(true).trustCertificate(ca)));
    }

    try (BufferedWriter w = Files.newBufferedWriter(
             out, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING)) {

      w.write("epoch_ms,op,outcome,latency_ms,region,detail");
      w.newLine();
      w.flush();

      // Cluster.connect can throw outright when nothing is reachable. Record
      // it as a line and exit 0: an empty CSV would make an assertion like
      // "zero successes" pass vacuously, which is worse than a visible failure.
      Cluster cluster;
      long tc = System.nanoTime();
      try {
        cluster = Cluster.connect(conn, opts);
      } catch (RuntimeException e) {
        record(w, "connect", "err", msSince(tc), "", brief(e));
        return;
      }

      try (Cluster c = cluster) {
        Bucket bucket = cluster.bucket(bucketName);
        Collection coll = bucket.defaultCollection();

        // Short timeouts so a dead upstream is recorded promptly instead of
        // stalling the loop and blurring the error window we are measuring.
        UpsertOptions up = UpsertOptions.upsertOptions().timeout(Duration.ofSeconds(2));
        GetOptions get = GetOptions.getOptions().timeout(Duration.ofSeconds(2));
        QueryOptions qo = QueryOptions.queryOptions().timeout(Duration.ofSeconds(5));

        long start = System.currentTimeMillis();
        long deadline = start + (runSeconds * 1000L);
        long sleepMs = Math.max(1, 1000L / Math.max(1, opsPerSec));
        long queryEvery = Math.max(1, (long) opsPerSec / Math.max(1, queryPerSec));
        long i = 0;
        boolean idleDone = idleAtSecond <= 0 || idleSeconds <= 0;

        while (System.currentTimeMillis() < deadline) {
          i++;

          if (!idleDone
              && System.currentTimeMillis() - start >= idleAtSecond * 1000L) {
            record(w, "idle", "ok", 0, "", "sleeping " + idleSeconds + "s");
            Thread.sleep(idleSeconds * 1000L);
            idleDone = true;
            deadline += idleSeconds * 1000L;
            continue;
          }

          String region = "";

          // The region marker is read first, so every later line in this
          // iteration is attributed to the cluster that actually served it.
          long t0 = System.nanoTime();
          try {
            JsonObject marker = coll.get("region::marker", get)
                .contentAsObject();
            region = marker.getString("region");
            record(w, "get", "ok", msSince(t0), region, "");
          } catch (RuntimeException e) {
            record(w, "get", "err", msSince(t0), region, brief(e));
          }

          t0 = System.nanoTime();
          try {
            coll.upsert("harness::" + (i % 100),
                JsonObject.create().put("i", i).put("ts", System.currentTimeMillis()),
                up);
            record(w, "upsert", "ok", msSince(t0), region, "");
          } catch (RuntimeException e) {
            record(w, "upsert", "err", msSince(t0), region, brief(e));
          }

          if (i % queryEvery == 0) {
            t0 = System.nanoTime();
            try {
              QueryResult qr = cluster.query(
                  "SELECT RAW COUNT(*) FROM `" + bucketName + "`", qo);
              List<Integer> rows = qr.rowsAs(Integer.class);
              record(w, "query", "ok", msSince(t0), region,
                  rows.isEmpty() ? "" : String.valueOf(rows.get(0)));
            } catch (RuntimeException e) {
              record(w, "query", "err", msSince(t0), region, brief(e));
            }
          }

          Thread.sleep(sleepMs);
        }
      }
    }
  }

  private static long msSince(long t0) {
    return (System.nanoTime() - t0) / 1_000_000L;
  }

  /** One short, CSV-safe token identifying the failure class. */
  private static String brief(RuntimeException e) {
    String n = e.getClass().getSimpleName();
    String m = e.getMessage() == null ? "" : e.getMessage();
    m = m.replaceAll("[,\\r\\n\"]", " ");
    if (m.length() > 80) {
      m = m.substring(0, 80);
    }
    return n + ": " + m;
  }

  private static void record(BufferedWriter w, String op, String outcome,
                             long latencyMs, String region, String detail)
      throws IOException {
    w.write(System.currentTimeMillis() + "," + op + "," + outcome + ","
        + latencyMs + "," + (region == null ? "" : region) + "," + detail);
    w.newLine();
    // Flushed per line: a killed container must still leave a usable CSV.
    w.flush();
  }
}
