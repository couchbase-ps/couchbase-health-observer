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
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class HarnessTest {
  @Test void eachOperationHasOnlyItsOwnRegionAndStartTime() throws Exception {
    Cluster cluster = mock(Cluster.class);
    Collection collection = mock(Collection.class);
    GetResult marker = mock(GetResult.class);
    when(marker.contentAsObject()).thenReturn(JsonObject.create().put("region", "a"));
    AtomicLong epoch = new AtomicLong(1000);
    AtomicLong nanos = new AtomicLong();
    when(collection.get(eq("region::marker"), any(GetOptions.class))).thenAnswer(call -> {
      epoch.addAndGet(80);
      nanos.addAndGet(80_000_000);
      return marker;
    });
    QueryResult query = mock(QueryResult.class);
    when(query.rowsAsObject()).thenReturn(List.of(JsonObject.create().put("region", "b").put("count", 12)));
    when(collection.upsert(anyString(), any(JsonObject.class), any(UpsertOptions.class))).thenAnswer(call -> {
      epoch.addAndGet(20);
      nanos.addAndGet(20_000_000);
      return null;
    });
    when(cluster.query(anyString(), any(QueryOptions.class))).thenAnswer(call -> {
      epoch.addAndGet(40);
      nanos.addAndGet(40_000_000);
      return query;
    });
    StringWriter csv = new StringWriter();
    Harness.runIteration(new BufferedWriter(csv), cluster, collection, "lbtest", 1, 1,
        UpsertOptions.upsertOptions(), GetOptions.getOptions(), QueryOptions.queryOptions(), epoch::get, nanos::get);
    String[] rows = csv.toString().split("\n");
    assertEquals(3, rows.length);
    String[] get = rows[0].split(",", -1);
    assertEquals("a", get[4]);
    assertEquals("1000", get[0], "timestamp must record request start");
    assertEquals("80", get[3]);
    assertEquals("1080", rows[1].split(",", -1)[0]);
    assertEquals("20", rows[1].split(",", -1)[3]);
    assertEquals("1100", rows[2].split(",", -1)[0]);
    assertEquals("40", rows[2].split(",", -1)[3]);
    assertEquals("", rows[1].split(",", -1)[4], "upsert cannot reuse previous GET marker");
    assertEquals("b", rows[2].split(",", -1)[4], "query must observe marker in its own result");
    verify(collection, times(1)).get(eq("region::marker"), any(GetOptions.class));
    verify(cluster).query(contains("region::marker"), any(QueryOptions.class));
  }

  @Test void failedQueryDoesNotInheritSuccessfulGetRegion() throws Exception {
    Cluster cluster = mock(Cluster.class);
    Collection collection = mock(Collection.class);
    GetResult marker = mock(GetResult.class);
    when(marker.contentAsObject()).thenReturn(JsonObject.create().put("region", "a"));
    when(collection.get(eq("region::marker"), any(GetOptions.class))).thenReturn(marker);
    when(cluster.query(anyString(), any(QueryOptions.class))).thenThrow(new IllegalStateException("unreachable"));
    StringWriter csv = new StringWriter();
    Harness.runIteration(new BufferedWriter(csv), cluster, collection, "lbtest", 1, 1,
        UpsertOptions.upsertOptions(), GetOptions.getOptions(), QueryOptions.queryOptions());
    String[] query = csv.toString().split("\n")[2].split(",", -1);
    assertEquals("err", query[2]);
    assertEquals("", query[4]);
  }
}
