# CNG and Envoy failover proof of concept

This stack tests whether an existing Java SDK client can reconnect through a load balancer when its Couchbase region fails. It is a repeatable proof of concept. It is not a production deployment or a product support commitment.

The configured path is Java SDK 3.7.4 -> Envoy TCP proxy -> CNG 1.2.1 -> Couchbase Server EE 8.0.3. The prior baseline and original KV-close panic were recorded with Server EE 8.0.1. TLS passes through Envoy to CNG. One passive Observer checks each region. Envoy reads the Observer verdict and decides when to move connections.

## Current validation result (2026-10-06, quiet host)

**Local validation passed; customer sign-off and merge remain blocked.** The default clean suite on runtime commit `d241a2d` exited 0 with Server EE 8.0.3, CNG 1.2.1, Envoy 1.31.10 and Java SDK 3.7.4 on Linux arm64. All scenarios 1–8 and 10, TLS controls and the readiness capture passed. Scenario 9 remains deferred. No assertions or operation budgets were relaxed, and no crash-masking restart was added.

| Check | Fresh result |
|---|---|
| Setup | Both regions passed topology, index, marker, Observer and Envoy gates |
| Healthy baseline | 1,014 successes, zero errors, region a only |
| One-node loss | 4,106 successes / 18 errors; all operations recovered; stayed in a; 5,060 ms no-success gap |
| Two-node loss | All operations recovered in b; 26,370 ms no-success gap; first b response 68,892 ms after fault |
| Whole-region loss | All operations recovered in b; 112,542 ms no-success gap; first b response 112,666 ms after fault |
| Recovery split | Old client: 8,501 successes in b; new client: 1,059 successes in a; zero errors; overlapping exact observations verified |
| Bootstrap-node loss | 5,027 successes / 24 errors; all operations recovered in a; 7,065 ms no-success gap |
| Backend health capture | All five backend nodes stopped: Observer DOWN, CNG `/health` still HTTP 200 |

The dual-outage, idle-client and verified-TLS checks also passed. The dual-outage workload made 16 failed KV requests and no successful requests. It contained **no query samples**, so this run does not validate SQL++ failure behavior during a dual outage. The wrong-CA control made eight failed KV requests with no successes, alongside direct certificate verification failure. The idle workload recorded 4,163 successes and no errors, including after its 60-second idle period.

Eleven completed CSV summaries were independently recalculated: counts, exact regions, no-success gaps and claimed terminal recovery flags agree. Resource and fault-time Observer/Envoy samples were retained alongside image identity and Docker exit/OOM metadata. Sampled host swap use stayed at zero; sampled Docker VM available memory stayed above 10 GiB; no Docker OOM-killed flag or unexpected gateway exit was observed. Final gateway logs contain no panic. Health polls were sequential at approximately five-second cadence, not atomic readings or exact Envoy decision timestamps.

Neither documented gateway panic reproduced in this quiet-host run. That does not establish their trigger or repair them: the original single-node run used a different Server maintenance release and host conditions, and current public upstream retains both source defects. Earlier failed evidence remains part of the assessment. No vendor-supported fixed image or documented workaround was established.

Remaining acceptance gates:

- Confirm a vendor-supported fix/version or documented applicable workaround for both recorded CNG panic paths.
- Validate combined gateway/data-path and database health. This configuration checks only Observer; a dead CNG can remain eligible when the database is healthy. CNG HTTP 200 alone also failed to detect the measured backend outage.
- Run required PR CI on the final branch. Local success does not establish the GitHub runner gate. No push or merge was performed in this continuation.

## Prior failed live validation (2026-10-06, before transfer)

**The handover was blocked.** Fresh arm64 run on commit `e451b7f`, with Server EE 8.0.1, passed setup and the healthy baseline (979 operations, zero measured errors). Scenario 2 then failed: CNG 1.2.1 crashed with a nil-pointer panic in `gocbcorex.(*kvClient).close` after one data node stopped. Couchbase auto-failover completed and the two remaining data nodes were healthy, but the workload did not recover. It recorded 66 errors and a 139,907 ms no-success gap. No region-b response was observed.

This confirms that gateway failure must be considered separately from database health. The current Observer-only health configuration does not provide that combined signal. The full suite stopped at this failure; later scenarios were not accepted as proven by this run. A vendor-supported gateway fix/version and a validated gateway-health or recovery policy are required before claiming completion. Unit tests and static review do not replace this failed live gate.

## Latest-version startup failures before transfer (2026-10-06)

A fresh registry check and pull confirmed that CNG 1.2.1 remains the latest public image. Its digest matches the image that crashed. The configuration now pins this digest and Server EE 8.0.3 by digest. [Server 8.0.3 release notes](https://docs.couchbase.com/server/current/release-notes/relnotes.html) identify the September 2026 maintenance release.

Neither latest-version startup attempt completed setup. The first failed the 300-second management readiness gate; Server logs show internal CouchDB startup timeouts during ALE log-sink registration. The second used byte-identical cached Observer binaries and sequential region startup, with no compilation. Management and authentication checks passed, then node convergence failed with curl exit 28. No fault scenario ran against Server 8.0.3. The host had heavy CPU use and active swapping. These failures do not establish that Server 8.0.3 causes or fixes the gateway panic.

Final evidence capture also found a different CNG panic after the cached startup failed. `cbauthx.(*RevRpcClient).Close` at `revrpcclient.go:166`, called from `NewCbAuthClient` at `cbauthclient.go:152`, crashed after authentication reconnect timeouts. The container exited at 09:34:05 UTC with exit code 2 and `OOMKilled=false`. This is a separate fault from the earlier KV-close panic. At handover, its source path and issue history had not yet been reviewed; the continuation findings below close that investigation scope. These metadata rule out a recorded Docker OOM kill for this gateway exit; they do not rule out host pressure as a trigger for connection timeouts.

A source audit found a possible initialization race: a read-error callback can call `kvClient.close` before its client field is assigned. A synthetic callback-order test reproduced the same panic location without network traffic. The relevant code is unchanged between the [image-recorded dependency revision](https://github.com/couchbase/gocbcorex/blob/c57d038398a3a4fbb6e3b3c4258f6a47fb6e46bd/kvclient.go) and [audited public revision](https://github.com/couchbase/gocbcorex/blob/299dda335412eff141d642a5ab6fb8bcc2ebbdb6/kvclient.go). This is a candidate cause, not proof of the actual callback order in the gateway run. Host pressure can change timing or cause connection errors; it does not establish an OOM cause or remove the software defect.

Continue on a quiet host. Retain Docker exit status, OOM flags, resource samples and both Observer and Envoy health readings. The continuation corrected the node-convergence transport retry escape before the clean run. No confirmed panic fix or applicable workaround was established. Customer readiness and merge validation remain blocked.

## Quiet-host investigation (2026-10-06)

The quiet-host source review now separates the authentication defect from the KV race. In the image-recorded [authentication constructor](https://github.com/couchbase/gocbcorex/blob/c57d038398a3a4fbb6e3b3c4258f6a47fb6e46bd/cbauthx/cbauthclient.go), cancellation before the first initialization event calls `cli.rpcCli.Close()` at line 152, although `cli.rpcCli` is assigned only at line 202. The pre-initialization reader-error branch at line 146 has the same ordering. A synthetic cancellation check with a valid transport reproduced the recorded stack on both the image revision and current public revision `299dda335412eff141d642a5ab6fb8bcc2ebbdb6`. The diagnostic also failed the upstream goroutine leak check. This establishes a sufficient source path, not a live gateway reproduction or proof of the original timeout trigger. The current upstream constructor is unchanged; its related reverse-RPC change only redacts logging.

Authorized read-only Jira review found no confirmed fix or documented workaround for either recorded stack. [ING-1294](https://couchbase.atlassian.net/browse/ING-1294) and [ING-1208](https://couchbase.atlassian.net/browse/ING-1208) remain unresolved related lifecycle races. Older authentication fixes, including [ING-780](https://couchbase.atlassian.net/browse/ING-780) and Server [MB-61619](https://couchbase.atlassian.net/browse/MB-61619), concern different failure paths and do not establish a remedy for the nil-close defect. [ING-2006](https://couchbase.atlassian.net/browse/ING-2006) fixes password logging, not a panic. Its CNG 1.2.2 target remains unreleased in Jira, and all 19 public registry tags contained no 1.2.2 image. Jira release flags also lag published 1.2.0/1.2.1 images, so those flags alone are not evidence of image availability. Searches covered returned descriptions and selected related comments; restricted issues, attachments and all possible queries were not covered.

The curl-28 setup escape is confirmed and corrected in `d241a2d`: the final join membership read previously ran outside the convergence retry. It now runs within the same 300-second budget; retries check existing membership before adding a node and retain the pending rebalance count. The regression failed before the correction. All 38 setup and 37 evidence tests pass, including persistent failure checks. This correction does not resolve either gateway panic.

The fresh release check still identifies CNG 1.2.1 and Server EE 8.0.3 at the pinned digests. The maintained 7.6 line's latest maintenance release is [7.6.12](https://docs.couchbase.com/server/7.6/release-notes/relnotes.html). The [enterprise support policy](https://www.couchbase.com/support-policy/enterprise-software/) gives Server 7.2 and subsequent major/minor releases a 36-month maintenance period from general availability; 7.6 and 8.0 remain within that period on this review date. Public image availability, compatibility and support entitlement are separate checks. CNG is not individually listed in that policy's lifespan table; exact deployment, gateway and required SDK support still need vendor confirmation. No supported fixed gateway replacement was established.

## Run the test

Use a dedicated test host with Docker Engine, Docker Compose v2, Bash, curl, jq, OpenSSL and Python 3. The stack starts six Couchbase Server containers, two gateways, two Observers, Envoy and a Java workload. Docker builds Java and Go images; no host JDK or Maven is needed. Allow about one hour, including first-time image downloads. CI sets a 60-minute limit. Resource use depends on the Docker host; provide sufficient free memory for all six database containers and avoid concurrent heavy tests.

Commands below run from the repository root:

```bash
# Fast offline regression checks, no cluster required.
test/compose-cng/setup_test.sh
test/compose-cng/evidence_test.sh

# Full run: creates a clean test stack, runs scenarios, saves evidence, then removes stack.
test/compose-cng/lb_e2e.sh

# Manual session: creates a clean test stack and leaves it running.
test/compose-cng/lb_e2e.sh up
test/compose-cng/lb_e2e.sh scenario 3
test/compose-cng/lb_e2e.sh readiness

# Removes only this test stack and its test database volumes.
test/compose-cng/lb_e2e.sh down
```

**Test data warning:** `up` and the full run first remove the existing `cng-a`, `cng-b` and `cng-lb` Compose projects and their database volumes. These commands also replace output in `/tmp/cng-lb-out`. Do not use these names or this directory for data that you need to retain. Copy each completed evidence set before starting another run. Run standalone scenario 2 before scenario 10; scenario 10 needs its same-run comparison baseline.

The Docker network is `cng-lb-net`, subnet `172.28.0.0/16`. Check that this subnet does not conflict with local or VPN routes. Container names and host ports must be free. Management ports bind to `127.0.0.1`:

| Host port | Service |
|---|---|
| 18098 | Envoy TLS passthrough listener |
| 19901 | Envoy admin |
| 8181 / 8182 | Observer in region a / b |
| 8191 / 8291 | Couchbase management in region a / b |
| 9191 / 9291 | CNG HTTP health in region a / b |

The full run uses the local Java client inside the test network. Default sample credentials, self-created certificates and fixed addresses are for this isolated stack only.

## What each scenario proves

| Scenario | Failure or condition | Required observation |
|---|---|---|
| 1 | Healthy baseline | Real GET, UPSERT and query traffic succeeds in region a |
| 2 | One data node stops | Auto-failover absorbs loss; traffic stays in a and all tested operations recover |
| 3 | Two data nodes stop | Health remains DOWN; existing client reconnects to b |
| 4 | Entire region a stops, including Observer and CNG | Client reconnects to b after health-check connection failures |
| 5 | Both regions stop | Real requests fail within operation timeout budgets; no success or hung workload |
| 6 | Client is idle for 60 seconds | Real requests succeed after it resumes |
| 7 | Region a recovers | Existing client stays in b; a new client chooses a; unreplicated data differs |
| 8 | Region switch with correct CA, plus wrong-CA control | Trusted TLS permits switch; wrong CA is rejected |
| 10 | CNG bootstrap node stops | CNG serves successful requests after cluster auto-failover; compared with scenario 2 |
| Readiness capture | All five database nodes in a stop, CNG stays running | Record both Observer status and CNG HTTP status, with a verified healthy baseline |

Scenario 9 (DNS steering) is deferred. Kubernetes Operator deployment, multiple gateways per region, quorum health, replication, coordinated failback and production load are outside this test.

## Read the evidence

A passing line is not enough. Read artifacts from the same run: per-operation CSVs, `<scenario>.summary.json`, workload exit codes, `commit.txt`, `run-id`, `fault-events.jsonl`, `s7.overlap.summary.json`, the three text evidence files and scoped logs/image metadata. A `.partial.summary.json` file describes an interrupted workload and cannot establish successful completion. CI uploads the directory as `cng-lb-output` on both success and failure.

Positive clients first wait for gRPC transport, then verify GET, UPSERT and query through the same client. All startup attempts remain in `<scenario>.startup.csv`; `<scenario>.startup.json` records readiness, duration and outcome. SDK `waitUntilReady()` alone checks transport for the pinned CNG SDK; it does not prove the backend bucket is ready. Driver waits for a current-run `<scenario>.ready.json` before starting its fault countdown. Intentionally down and wrong-CA workloads disable positive startup readiness and record that mode explicitly.

`RUN_SECONDS` and the main CSV start after successful startup. A startup error is retained in startup evidence; it does not become an ignored measurement error. Fault and reconnect errors stay in the main CSV. The measured request budgets remain GET/UPSERT 2s and query 5s. A zero-error healthy baseline remains mandatory.

CSV rows contain operation start time (`epoch_ms`), operation, result, latency, exact observed region where available, and error detail. A successful marker GET proves its own region. A query can return its marker in the same request. UPSERT has no exact region label: a preceding GET can be served by another region if the connection moves between requests. Do not infer write placement from the previous read.

Keep three different measures separate:

- **No-success gap:** longest sampled interval with no successful operation of any type. Interleaved reads can hide a persistent write failure. This is not full recovery time.
- **Operation recovery:** failure period and final successful interval for GET, UPSERT and query separately. Each operation needs a final successful interval of at least 10 seconds, with samples no more than 5 seconds apart and a last sample within 5 seconds of workload end. A workload that ends while one operation type still fails has not recovered.
- **First observed region-b response after fault injection:** client observation of routing change. It is not the exact Envoy decision time.

Each measured result applies to one recorded run, test load, configuration and host. Do not use an earlier sample range as a guaranteed recovery time. Whole-region loss and partial node loss use different detection paths and must be reported separately. The serial harness targets 20 loop iterations per second; each iteration performs a GET and UPSERT, plus periodic queries. It does not produce exactly 20 operations per second. During failures, operation timeouts reduce throughput.

The idle test covers 60 seconds. It does not test the configured one-hour idle expiry. The TLS test checks server certificate trust between SDK and CNG. It does not test client certificate authentication or TLS between CNG/Observer and Couchbase Server. The tested backend links use plaintext; production transport protection needs separate configuration and validation. The no-replication test proves availability and routing, not data continuity.

## Settings required for this test

| Setting | Value and reason |
|---|---|
| Separate health target | Traffic uses CNG; health check uses the region Observer at a different literal IP |
| HTTP retriable status | Include 503 so repeated DOWN verdicts count toward `unhealthy_threshold` |
| Health interval / failures | 5s / 12; consecutive failures debounce an absorbed node loss |
| Observer ping / Envoy timeout | 1s per ping, two sequential pings; Envoy timeout 4s allows margin over the approximately 2s probe budget |
| Connection eviction | `close_connections_on_host_health_failure: true` forces existing TCP channels to reconnect |
| Dual-outage handling | `fail_traffic_on_panic: true` prevents selection of known unhealthy hosts |
| TLS passthrough | Certificates at both CNG endpoints must cover the name the client uses for the load balancer |
| Idle timeout | 3600s, longer than the idle interval exercised here |

The 5s interval and 12 failures do not promise an exact 60s wall-clock switch. Check duration, scheduling, phase offset and SDK reconnect time add delay. The Observer checks critical `kv` in this stack. Query is tested by traffic but does not drive the global health decision. Applications that require query must evaluate their critical-service choice.

Generated certificates use one test CA and one shared server key. Production gateways can use separate keys and certificates, provided each certificate covers the load-balancer hostname and chains to a trusted CA. Keep CA and server private keys out of source control. Replace sample administrator access with the required least-privilege identities before production deployment.

## Limits that affect a customer design

**Recovery can split clients between regions.** Envoy priority routing selects a host when a connection opens. When a fails, connection eviction moves existing clients to b. When a recovers, existing clients can stay in b while new clients select a. Do not treat this as coordinated failback. Keep the recovered region excluded until an operator has reconciled data and moved clients together. This test has no such latch or control procedure. A production load balancer or control plane must provide one.

**Observer does not prove gateway health.** Its health target checks the database, not the gateway process or data port. A dead CNG with a healthy database can remain an eligible target. Scenario 10 tests one bootstrap-node failure; it does not close this general gap. A production design must combine database health with gateway/data-path health and test gateway failure separately.

**No XDCR means no data continuity.** The regions hold different data. A successful write to b may not be visible in a. Define replication, conflict handling and recovery-point requirements before a production switch.

**This stack has single instances.** One Observer, one CNG and one Envoy per tested role are not an HA production topology. Multiple health sensors need an explicit aggregation rule; adding independent Observer checks is not a tested quorum design. Test load, network partitions, asymmetric failures, certificate expiry and application retry behavior require separate validation.

**Support depends on the exact deployment and SDK.** Current Couchbase documentation describes [standalone Docker and VM deployment](https://docs.couchbase.com/cloud-native-gateway/current/Deployment/deploying-self-managed.html). The earlier claim that standalone CNG was undocumented is obsolete. This PoC does not establish a support contract. Current [CNG capability documentation](https://docs.couchbase.com/cloud-native-gateway/current/intro/supported-unsupported-capabilities.html) and [Node.js compatibility documentation](https://docs.couchbase.com/nodejs-sdk/current/project-docs/compatibility.html) disagree on Node.js availability. This test proves Java SDK 3.7.4 only. Confirm support for each required SDK and version with Couchbase before committing to a customer design.

CNG 1.2.1 INFO logs in this test include the backend authentication password inside connection configuration. The stack uses dummy credentials. Review gateway logging and credential handling before using real credentials, and do not publish production gateway logs as PoC evidence.

## Product health observation

The readiness capture tests `/health` on CNG 1.2.1 while all its backend nodes are stopped. If the response remains 200 while Observer reports DOWN, the narrow finding is: **this endpoint did not detect this backend outage in this run**. It does not prove that the endpoint can never return 503, or that every CNG version behaves the same way.

[Load-balancer documentation](https://docs.couchbase.com/cloud-native-gateway/current/sizing-performance-guidance/load-balancer-considerations.html) describes `/ready` and `/health` as aliases. This suite measures `/health`; it does not independently test `/ready` or the gRPC health service. Any explanation based on another source tag remains an inference until matched to the exact image build.

## Merge gate

Run offline regression checks, Go tests/vet/build, Compose configuration validation, Envoy validation and the complete CNG scenario suite on the final commit. Read and retain that run's summary and evidence. Rebase on current `main` and run required PR CI before merge. A local green run does not prove the GitHub runner gate. Production approval requires the separate decisions listed above.
