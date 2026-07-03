# Runbook: Observer failover & failback

## What happens on a sustained primary outage (automatic)
1. The observer pings the primary each `--interval`; a critical service (e.g. `kv`)
   becomes unreachable -> global status `DOWN`.
2. The state machine requires `DOWN` sustained past `--failover-delay` (transient or
   auto-failover-absorbed losses do NOT switch). It also requires the cluster to have
   been seen healthy at least once (cold-start guard).
3. Secondary guard: before switching, the observer probes the secondary. If it is not
   ready, the switch is held (metric `observer_secondary_up=0`, log
   `switch held: secondary not ready`) and retried next tick.
4. On switch: the observer patches `cb-conn.connstring` to the secondary and
   `rollout restart`s the configured Deployments. Apps reconnect on restart.
   `observer_failover_total` increments; `observer_active_region` flips.

## Manual failback (operator-driven — never automatic)
After the primary recovers to healthy:

    # 1. Confirm the primary is healthy again (all data nodes Ready).
    kubectl -n region-a get pods -l couchbase_cluster=region-a

    # 2. Point cb-conn back to the primary.
    kubectl patch configmap cb-conn -p '{"data":{"connstring":"couchbase://region-a-srv.region-a.svc"}}'

    # 3. Roll the apps so they reconnect to the primary.
    kubectl rollout restart deployment/mock-app

    # 4. If the observer holds long-lived SDK connections to a rebuilt primary, roll it too.
    kubectl rollout restart deployment/observer

Failback is manual by design: the operator decides when the primary is trustworthy.

## Quorum-loss recovery (AWS eks-demo, ephemeral nodes)
If a test kills a majority of primary data nodes, Couchbase refuses failover and the
operator waits for manual action. Recreate the region (no PVCs = no data loss):
`helm uninstall` + reinstall the region chart, then reconnect the observer and flip
`cb-conn` back. (See the Emirates demo runbook "Failback gotcha" callout.)
