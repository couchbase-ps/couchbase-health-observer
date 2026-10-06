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
import java.util.function.LongSupplier;

/**
 * Availability harness for the CNG load-balancer test.
 *
 * Drives KV and SQL++ through whatever endpoint CB_CONN names, and records one
 * CSV line per operation. It never throws out of the loop: a failure is the
 * measurement, not an error.
 *
 * The region column comes from a marker document written into each cluster by
 * init-cluster.sh. GET and query observations are exact for their own request.
 * Upsert attribution is unavailable and stays blank. No XDCR is configured.
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

      // Startup failures are diagnostics, not completed workload evidence.
      Cluster cluster;
      long connectStart = System.currentTimeMillis();
      long tc = System.nanoTime();
      try {
        cluster = Cluster.connect(conn, opts);
      } catch (RuntimeException e) {
        record(w, connectStart, "connect", "err", msSince(tc), "", brief(e));
        throw e;
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
            record(w, System.currentTimeMillis(), "idle", "ok", 0, "", "sleeping " + idleSeconds + "s");
            Thread.sleep(idleSeconds * 1000L);
            idleDone = true;
            deadline += idleSeconds * 1000L;
            continue;
          }

          runIteration(w, cluster, coll, bucketName, i, queryEvery, up, get, qo);

          Thread.sleep(sleepMs);
        }
      }
    }
  }

  static void runIteration(BufferedWriter w, Cluster cluster, Collection coll,
                           String bucketName, long i, long queryEvery,
                           UpsertOptions up, GetOptions get, QueryOptions qo) throws IOException {
    runIteration(w, cluster, coll, bucketName, i, queryEvery, up, get, qo,
        System::currentTimeMillis, System::nanoTime);
  }

  static void runIteration(BufferedWriter w, Cluster cluster, Collection coll,
                           String bucketName, long i, long queryEvery,
                           UpsertOptions up, GetOptions get, QueryOptions qo,
                           LongSupplier epochMillis, LongSupplier nanoTime) throws IOException {
    long started = epochMillis.getAsLong();
    long t0 = nanoTime.getAsLong();
    try {
      JsonObject marker = coll.get("region::marker", get).contentAsObject();
      record(w, started, "get", "ok", msSince(t0, nanoTime), marker.getString("region"), "");
    } catch (RuntimeException e) {
      record(w, started, "get", "err", msSince(t0, nanoTime), "", brief(e));
    }

    started = epochMillis.getAsLong();
    t0 = nanoTime.getAsLong();
    try {
      coll.upsert("harness::" + (i % 100),
          JsonObject.create().put("i", i).put("ts", started), up);
      record(w, started, "upsert", "ok", msSince(t0, nanoTime), "", "");
    } catch (RuntimeException e) {
      record(w, started, "upsert", "err", msSince(t0, nanoTime), "", brief(e));
    }

    if (i % queryEvery == 0) {
      started = epochMillis.getAsLong();
      t0 = nanoTime.getAsLong();
      try {
        QueryResult qr = cluster.query(
            "SELECT m.region AS region, (SELECT RAW COUNT(*) FROM `" + bucketName
                + "`)[0] AS count FROM `" + bucketName + "` AS m USE KEYS \"region::marker\"", qo);
        List<JsonObject> rows = qr.rowsAsObject();
        JsonObject row = rows.isEmpty() ? null : rows.get(0);
        record(w, started, "query", "ok", msSince(t0, nanoTime), row == null ? "" : row.getString("region"),
            row == null ? "" : String.valueOf(row.get("count")));
      } catch (RuntimeException e) {
        record(w, started, "query", "err", msSince(t0, nanoTime), "", brief(e));
      }
    }
  }

  private static long msSince(long t0) {
    return msSince(t0, System::nanoTime);
  }

  private static long msSince(long t0, LongSupplier nanoTime) {
    return (nanoTime.getAsLong() - t0) / 1_000_000L;
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

  private static void record(BufferedWriter w, long startedMs, String op, String outcome,
                             long latencyMs, String region, String detail)
      throws IOException {
    w.write(startedMs + "," + op + "," + outcome + ","
        + latencyMs + "," + (region == null ? "" : region) + "," + detail);
    w.newLine();
    // Flushed per line: a killed container must still leave a usable CSV.
    w.flush();
  }
}
