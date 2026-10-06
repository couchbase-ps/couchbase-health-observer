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
import java.nio.file.StandardCopyOption;
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

    Path startupCsv = Paths.get(env("STARTUP_CSV", out.toString().replaceFirst("\\.csv$", "") + ".startup.csv"));
    Path readyFile = Paths.get(env("READY_FILE", out.toString().replaceFirst("\\.csv$", "") + ".ready.json"));
    Path startupJson = Paths.get(startupCsv.toString().replaceFirst("\\.csv$", "") + ".json");
    String runId = env("RUN_ID", "standalone");
    String startupMode = env("STARTUP_REQUIRED", "true");
    if (!startupMode.equals("true") && !startupMode.equals("false")) {
      throw new IllegalArgumentException("STARTUP_REQUIRED must be true or false");
    }
    boolean startupRequired = Boolean.parseBoolean(startupMode);
    String expectedRegion = env("EXPECTED_REGION", "a");
    if (!expectedRegion.equals("a") && !expectedRegion.equals("b")) {
      throw new IllegalArgumentException("EXPECTED_REGION must be a or b");
    }
    Files.deleteIfExists(readyFile);
    Files.createDirectories(out.toAbsolutePath().getParent());
    Files.createDirectories(startupCsv.toAbsolutePath().getParent());

    ClusterOptions opts = ClusterOptions.clusterOptions(user, pass);
    if (!tlsCa.isBlank()) {
      Path ca = Paths.get(tlsCa);
      opts = opts.environment(env -> env.securityConfig(
          sec -> sec.enableTls(true).trustCertificate(ca)));
    }

    long startupStart = System.currentTimeMillis();
    try (BufferedWriter startup = csvWriter(startupCsv)) {
      Cluster cluster;
      long tc = System.nanoTime();
      try {
        cluster = Cluster.connect(conn, opts);
        record(startup, startupStart, "connect", "ok", msSince(tc), "", "");
      } catch (RuntimeException e) {
        record(startup, startupStart, "connect", "err", msSince(tc), "", brief(e));
        writeJson(startupJson, startupMetadata(runId, startupRequired, startupStart, 0,
            new StartupResult(false, "", 0, 0, 0, "connect_failed")));
        throw e;
      }

      try (Cluster c = cluster) {
        Bucket bucket = cluster.bucket(bucketName);
        Collection coll = bucket.defaultCollection();
        StartupResult result = runStartup(startup, cluster, coll, bucketName, expectedRegion,
            startupRequired, System::currentTimeMillis, System::nanoTime);
        if (startupRequired && !result.ready()) {
          writeJson(startupJson, startupMetadata(runId, true, startupStart, 0, result));
          throw new IllegalStateException("startup readiness failed: " + result.result());
        }

        // These budgets apply unchanged to startup and all measured requests.
        UpsertOptions up = upsertOptions();
        GetOptions get = getOptions();
        QueryOptions qo = queryOptions();
        try (BufferedWriter w = csvWriter(out)) {
          long start = System.currentTimeMillis();
          JsonObject metadata = startupMetadata(runId, startupRequired, startupStart, start, result);
          writeJson(startupJson, metadata);
          writeJson(readyFile, metadata);
          long deadline = start + (runSeconds * 1000L);
          long sleepMs = Math.max(1, 1000L / Math.max(1, opsPerSec));
          long queryEvery = Math.max(1, (long) opsPerSec / Math.max(1, queryPerSec));
          long i = 0;
          boolean idleDone = idleAtSecond <= 0 || idleSeconds <= 0;

          while (System.currentTimeMillis() < deadline) {
            i++;
            if (!idleDone && System.currentTimeMillis() - start >= idleAtSecond * 1000L) {
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
  }

  private static UpsertOptions upsertOptions() {
    return UpsertOptions.upsertOptions().timeout(Duration.ofSeconds(2));
  }

  private static GetOptions getOptions() {
    return GetOptions.getOptions().timeout(Duration.ofSeconds(2));
  }

  private static QueryOptions queryOptions() {
    return QueryOptions.queryOptions().timeout(Duration.ofSeconds(5));
  }

  record StartupResult(boolean ready, String observedRegion, int attempts,
                       long transportWaitMs, long startupDataMs, String result) {}

  static StartupResult runStartup(BufferedWriter w, Cluster cluster, Collection coll,
                                 String bucket, String expectedRegion, boolean required,
                                 LongSupplier epochMillis, LongSupplier nanoTime) throws IOException {
    if (!required) {
      record(w, epochMillis.getAsLong(), "startup", "ok", 0, "", "disabled");
      return new StartupResult(false, "", 0, 0, 0, "disabled");
    }
    long started = epochMillis.getAsLong();
    long transportStart = nanoTime.getAsLong();
    try {
      // Java SDK 3.7.4 CNG readiness polls gRPC transport only, not backend data paths.
      cluster.waitUntilReady(Duration.ofSeconds(30));
      record(w, started, "transport", "ok", msSince(transportStart, nanoTime), "", "grpc_only");
    } catch (RuntimeException e) {
      long latency = msSince(transportStart, nanoTime);
      record(w, started, "transport", "err", latency, "", brief(e));
      return new StartupResult(false, "", 0, latency, 0, "transport_failed");
    }
    long transportMs = msSince(transportStart, nanoTime);
    long dataStart = nanoTime.getAsLong();
    long deadline = dataStart + Duration.ofSeconds(30).toNanos();
    int attempts = 0;
    while (canStart(deadline, 2, nanoTime)) {
      attempts++;
      Pass pass = runPass(w, cluster, coll, bucket, 0, 1, upsertOptions(), getOptions(), queryOptions(),
          epochMillis, nanoTime, deadline);
      if (!pass.complete() || nanoTime.getAsLong() > deadline) break;
      // A successful response from another region must never establish expected readiness.
      if ((!pass.getRegion().isEmpty() && !pass.getRegion().equals(expectedRegion))
          || (!pass.queryRegion().isEmpty() && !pass.queryRegion().equals(expectedRegion))) {
        String observed = !pass.getRegion().isEmpty() && !pass.getRegion().equals(expectedRegion)
            ? pass.getRegion() : pass.queryRegion();
        return new StartupResult(false, observed, attempts, transportMs,
            msSince(dataStart, nanoTime), "wrong_region");
      }
      if (pass.success() && pass.getRegion().equals(expectedRegion) && pass.queryRegion().equals(expectedRegion)) {
        return new StartupResult(true, expectedRegion, attempts, transportMs,
            msSince(dataStart, nanoTime), "ready");
      }
    }
    return new StartupResult(false, "", attempts, transportMs, msSince(dataStart, nanoTime), "data_deadline");
  }

  private static BufferedWriter csvWriter(Path path) throws IOException {
    BufferedWriter writer = Files.newBufferedWriter(path, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING);
    writer.write("epoch_ms,op,outcome,latency_ms,region,detail");
    writer.newLine();
    writer.flush();
    return writer;
  }

  private static JsonObject startupMetadata(String runId, boolean required, long startupStart,
                                            long measuredStart, StartupResult result) {
    return JsonObject.create().put("run_id", runId).put("warmup_required", required)
        .put("ready", result.ready()).put("observed_region", result.observedRegion())
        .put("measurement_start_epoch_ms", measuredStart > 0 ? measuredStart : null)
        .put("startup_start_epoch_ms", startupStart).put("transport_wait_ms", result.transportWaitMs())
        .put("startup_data_ms", result.startupDataMs()).put("startup_attempts", result.attempts())
        .put("result", result.result());
  }

  private static void writeJson(Path path, JsonObject metadata) throws IOException {
    Files.createDirectories(path.toAbsolutePath().getParent());
    Path temp = Files.createTempFile(path.toAbsolutePath().getParent(), ".readiness-", ".tmp");
    try {
      Files.writeString(temp, metadata.toString() + "\n");
      Files.move(temp, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
    } finally {
      Files.deleteIfExists(temp);
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
    runPass(w, cluster, coll, bucketName, i, queryEvery, up, get, qo,
        epochMillis, nanoTime, Long.MAX_VALUE);
  }

  private record Pass(boolean complete, boolean success, String getRegion, String queryRegion) {}

  private static boolean canStart(long deadline, int timeoutSeconds, LongSupplier nanoTime) {
    return deadline == Long.MAX_VALUE || deadline - nanoTime.getAsLong() >= Duration.ofSeconds(timeoutSeconds).toNanos();
  }

  private static Pass runPass(BufferedWriter w, Cluster cluster, Collection coll,
                              String bucketName, long i, long queryEvery,
                              UpsertOptions up, GetOptions get, QueryOptions qo,
                              LongSupplier epochMillis, LongSupplier nanoTime, long deadline) throws IOException {
    boolean getOk = false, upsertOk = false, queryOk = false;
    String getRegion = "", queryRegion = "";
    if (!canStart(deadline, 2, nanoTime)) return new Pass(false, false, getRegion, queryRegion);
    long started = epochMillis.getAsLong();
    long t0 = nanoTime.getAsLong();
    try {
      JsonObject marker = coll.get("region::marker", get).contentAsObject();
      getRegion = marker.getString("region");
      if (getRegion == null) getRegion = "";
      getOk = true;
      record(w, started, "get", "ok", msSince(t0, nanoTime), getRegion, "");
    } catch (RuntimeException e) {
      record(w, started, "get", "err", msSince(t0, nanoTime), "", brief(e));
    }

    if (!canStart(deadline, 2, nanoTime)) return new Pass(false, false, getRegion, queryRegion);
    started = epochMillis.getAsLong();
    t0 = nanoTime.getAsLong();
    try {
      coll.upsert("harness::" + (i % 100),
          JsonObject.create().put("i", i).put("ts", started), up);
      upsertOk = true;
      record(w, started, "upsert", "ok", msSince(t0, nanoTime), "", "");
    } catch (RuntimeException e) {
      record(w, started, "upsert", "err", msSince(t0, nanoTime), "", brief(e));
    }

    if (i % queryEvery == 0) {
      if (!canStart(deadline, 5, nanoTime)) return new Pass(false, false, getRegion, queryRegion);
      started = epochMillis.getAsLong();
      t0 = nanoTime.getAsLong();
      try {
        QueryResult qr = cluster.query(
            "SELECT m.region AS region, (SELECT RAW COUNT(*) FROM `" + bucketName
                + "`)[0] AS count FROM `" + bucketName + "` AS m USE KEYS \"region::marker\"", qo);
        List<JsonObject> rows = qr.rowsAsObject();
        JsonObject row = rows.isEmpty() ? null : rows.get(0);
        queryRegion = row == null ? "" : row.getString("region");
        if (queryRegion == null) queryRegion = "";
        queryOk = true;
        record(w, started, "query", "ok", msSince(t0, nanoTime), queryRegion,
            row == null ? "" : String.valueOf(row.get("count")));
      } catch (RuntimeException e) {
        record(w, started, "query", "err", msSince(t0, nanoTime), "", brief(e));
      }
    }
    return new Pass(true, getOk && upsertOk && queryOk, getRegion, queryRegion);
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
