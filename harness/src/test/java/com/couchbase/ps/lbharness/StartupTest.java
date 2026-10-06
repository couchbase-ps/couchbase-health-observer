package com.couchbase.ps.lbharness;

import com.couchbase.client.java.Cluster;
import com.couchbase.client.java.Collection;
import com.couchbase.client.java.json.JsonObject;
import com.couchbase.client.java.kv.GetOptions;
import com.couchbase.client.java.kv.GetResult;
import com.couchbase.client.java.kv.UpsertOptions;
import com.couchbase.client.java.query.QueryOptions;
import com.couchbase.client.java.query.QueryResult;
import org.junit.jupiter.api.Test;
import java.io.BufferedWriter;
import java.io.StringWriter;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class StartupTest {
  final Cluster cluster = mock(Cluster.class);
  final Collection collection = mock(Collection.class);
  final AtomicLong clock = new AtomicLong();
  final StringWriter csv = new StringWriter();

  void healthy(String getRegion, String queryRegion) {
    GetResult get = mock(GetResult.class);
    when(get.contentAsObject()).thenReturn(JsonObject.create().put("region", getRegion));
    when(collection.get(eq("region::marker"), any(GetOptions.class))).thenAnswer(call -> {
      assertEquals(Duration.ofSeconds(2), ((GetOptions) call.getArgument(1)).build().timeout().orElseThrow());
      clock.addAndGet(10_000_000); return get;
    });
    when(collection.upsert(eq("harness::0"), any(JsonObject.class), any(UpsertOptions.class))).thenAnswer(call -> {
      assertEquals(Duration.ofSeconds(2), ((UpsertOptions) call.getArgument(2)).build().timeout().orElseThrow());
      clock.addAndGet(10_000_000); return null;
    });
    QueryResult result = mock(QueryResult.class);
    when(result.rowsAsObject()).thenReturn(List.of(JsonObject.create().put("region", queryRegion).put("count", 5)));
    when(cluster.query(contains("region::marker"), any(QueryOptions.class))).thenAnswer(call -> {
      assertEquals(Duration.ofSeconds(5), ((QueryOptions) call.getArgument(1)).build().timeout().orElseThrow());
      clock.addAndGet(10_000_000); return result;
    });
  }

  Harness.StartupResult startup(boolean required) throws Exception {
    return Harness.runStartup(new BufferedWriter(csv), cluster, collection, "lbtest", "a", required,
        () -> 1000 + clock.get() / 1_000_000, clock::get);
  }

  @Test void coldGetFailureRemainsRecordedBeforeCompleteReadyPass() throws Exception {
    healthy("a", "a");
    GetResult get = mock(GetResult.class);
    when(get.contentAsObject()).thenReturn(JsonObject.create().put("region", "a"));
    AtomicLong requests = new AtomicLong();
    when(collection.get(eq("region::marker"), any(GetOptions.class))).thenAnswer(call -> {
      if (requests.getAndIncrement() == 0) {
        clock.addAndGet(2_000_000_000L); throw new IllegalStateException("cold backend");
      }
      clock.addAndGet(10_000_000); return get;
    });
    Harness.StartupResult result = startup(true);
    assertTrue(result.ready()); assertEquals("a", result.observedRegion());
    assertEquals(2, result.attempts());
    String[] rows = csv.toString().split("\n");
    assertEquals(7, rows.length, "transport plus every data request retained");
    assertEquals("1000,get,err,2000,,IllegalStateException: cold backend", rows[1]);
    assertEquals("", rows[2].split(",", -1)[4], "startup upsert provenance remains unknown");
    verify(cluster).waitUntilReady(Duration.ofSeconds(30));
  }

  @Test void persistentFailuresExhaustSharedDeadlineWithoutFalseReady() throws Exception {
    healthy("a", "a");
    when(collection.get(eq("region::marker"), any(GetOptions.class))).thenAnswer(call -> {
      clock.addAndGet(2_000_000_000L); throw new IllegalStateException("dead backend");
    });
    Harness.StartupResult result = startup(true);
    assertFalse(result.ready()); assertTrue(result.attempts() > 1);
    assertTrue(clock.get() <= 30_000_000_000L, "no operation starts without its full timeout remaining");
    assertTrue(csv.toString().contains("get,err,2000"));
  }

  @Test void mismatchedGetOrQueryRegionNeverProducesReady() throws Exception {
    healthy("a", "b");
    assertFalse(startup(true).ready());
    assertTrue(csv.toString().contains("query,ok,10,b,5"), "wrong-region success retained as evidence");
  }

  @Test void failedWriteCannotBeHiddenBySuccessfulReadAndQuery() throws Exception {
    healthy("a", "a");
    when(collection.upsert(anyString(), any(JsonObject.class), any(UpsertOptions.class))).thenAnswer(call -> {
      clock.addAndGet(2_000_000_000L); throw new IllegalStateException("write denied");
    });
    assertFalse(startup(true).ready()); assertTrue(csv.toString().contains("upsert,err,2000"));
  }

  @Test void negativeModeSkipsTransportAndPositiveRequests() throws Exception {
    Harness.StartupResult result = startup(false);
    assertFalse(result.ready()); assertEquals(0, result.attempts());
    verifyNoInteractions(cluster, collection);
    assertTrue(csv.toString().contains("startup,ok,0,,disabled"));
    when(collection.get(anyString(), any(GetOptions.class))).thenThrow(new IllegalStateException("negative request"));
    Harness.runIteration(new BufferedWriter(csv), cluster, collection, "lbtest", 1, 1,
        UpsertOptions.upsertOptions().timeout(Duration.ofSeconds(2)),
        GetOptions.getOptions().timeout(Duration.ofSeconds(2)),
        QueryOptions.queryOptions().timeout(Duration.ofSeconds(5)));
    assertTrue(csv.toString().contains("get,err"));
    verify(collection).get(eq("region::marker"), any(GetOptions.class));
    verify(cluster).query(contains("region::marker"), any(QueryOptions.class));
  }

  @Test void transportFailureIsRecordedAndCannotDeclareDataReady() throws Exception {
    doAnswer(call -> { clock.addAndGet(30_000_000_000L); throw new IllegalStateException("transport down"); })
        .when(cluster).waitUntilReady(Duration.ofSeconds(30));
    assertFalse(startup(true).ready());
    assertTrue(csv.toString().contains("transport,err,30000,,IllegalStateException: transport down"));
    verifyNoInteractions(collection);
  }
  @Test void successReturningAfterDeadlineCannotDeclareReady() throws Exception {
    healthy("a", "a");
    QueryResult query = mock(QueryResult.class);
    when(query.rowsAsObject()).thenReturn(List.of(JsonObject.create().put("region", "a")));
    when(cluster.query(anyString(), any(QueryOptions.class))).thenAnswer(call -> {
      // A delayed scheduler can return an SDK result after the startup deadline.
      clock.addAndGet(30_000_000_000L); return query;
    });
    assertFalse(startup(true).ready());
    assertTrue(csv.toString().contains("query,ok,30000,a,"));
  }

  @Test void wrongGetRegionCannotBeOverruledByCorrectQueryRegion() throws Exception {
    healthy("b", "a");
    Harness.StartupResult result = startup(true);
    assertFalse(result.ready());
    assertEquals("b", result.observedRegion(), "metadata retains the region that rejected readiness");
    assertTrue(csv.toString().contains("get,ok,10,b,"));
  }

}
