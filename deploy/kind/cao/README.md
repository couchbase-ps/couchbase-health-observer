# Couchbase Helm deployment

`deploy/kind/couchbase-cluster` is a dependency-only wrapper around the official
Couchbase Operator chart. It contains no Couchbase templates of its own.

Pinned versions:

- official chart: `couchbase-operator` `2.92.0`
- Couchbase Autonomous Operator: `2.9.2`
- Couchbase Server: `8.0.1`

The e2e installs the same wrapper twice, once per namespace:

1. `region-a` deploys CAO, the admission controller, and the primary cluster.
2. `region-b` deploys CAO, the admission controller, and the secondary cluster.

This is the same dependency-wrapper pattern as the
`cao-eviction-reschedule-hook/couchbase-cluster` example. Separate namespaces
avoid Helm ownership and generated-resource name collisions between regions.

On a completely fresh kind node, Kubernetes can register the validating webhook
before its image has finished pulling. `test/e2e_switch.sh` retries the same Helm
release only for that verified `connection refused` startup race, with at most
three total Helm attempts.

Run `helm dependency build deploy/kind/couchbase-cluster` after changing the
dependency version.
