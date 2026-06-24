# deploy/aws/lambda — switch Lambda

SNS-triggered Lambda that performs the region switch when the distributed-quorum alarm
fires. It reuses the same actuator as the observer's active mode (`pkg/actuator`): it
patches the connection-string ConfigMap to the secondary cluster and rolls the dependent
Deployments. It acts **only on the ALARM transition** (failback is manual) and is
idempotent (a duplicate ALARM is a no-op).

This is a separate Terraform root from the aggregation module (`deploy/aws`) so the
module's apply path never depends on a built Lambda artifact. It takes the aggregation
module's `switch_sns_topic_arn` output as an input.

## Build

```bash
./build.sh        # builds the linux/arm64 'bootstrap' binary into this directory
```

Terraform zips that binary (via the `archive` provider) at apply time.

## Deploy

Apply the aggregation module (`deploy/aws`) first, then pass its SNS topic ARN:

```bash
./build.sh
terraform init
terraform apply \
  -var switch_sns_topic_arn="$(terraform -chdir=.. output -raw switch_sns_topic_arn)" \
  -var secondary_conn=couchbase://region-b-srv.region-b.svc \
  -var deployments=mock-app \
  -var 'subnet_ids=["<subnet-a>","<subnet-b>"]' \
  -var 'security_group_ids=["<sg>"]'
```

`subnet_ids` / `security_group_ids` place the Lambda in the VPC so it can reach a private
EKS API endpoint; omit them to run outside a VPC. Set `-var dry_run=true` for a first run
that logs the intended switch without changing anything.

## Grant the Lambda Kubernetes access (environment-specific)

The Lambda role (output `lambda_role_arn`) needs RBAC on the target cluster. On EKS, map
it with an access entry scoped to the one namespace:

```bash
aws eks create-access-entry --cluster-name <cluster> --principal-arn <lambda_role_arn> --type STANDARD
aws eks associate-access-policy --cluster-name <cluster> --principal-arn <lambda_role_arn> \
  --access-scope type=namespace,namespaces=default \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy
```

(Prefer a custom policy granting only `get`/`update` on the `cb-conn` ConfigMap and the
named Deployments.) The binary builds its Kubernetes client from `KUBECONFIG` if set,
otherwise in-cluster config; supplying the Lambda a kubeconfig/token for the EKS endpoint
is the environment-specific wiring.

## Safety

- Acts only on the **ALARM** transition. OK (recovery) does nothing: **failback is manual**.
- **Idempotent**: if the ConfigMap is already on the secondary, it is a no-op.
- `dry_run=true` logs the intended switch without mutating anything (good for the first run).

## Validation

- Unit: event parsing (`pkg/event`) and the actuate-only-on-ALARM handler (`pkg/switchhandler`).
- Real switch on Kubernetes: `test/kind/switch_lambda_e2e.sh` (kind; ALARM switches + rolls, OK is a no-op).
- SNS → Lambda trigger wiring: `PHASE=lambda ./test/aws/localstack.sh` (LocalStack; real binary invoked by SNS; runs on the free tier, no elbv2 license needed).
- `terraform validate` for this module.
