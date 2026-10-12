# CNG and Envoy demo on EKS

This demo places applications, Envoy and standalone CNG pods on EKS. The Operator manages two separate Couchbase clusters. All resources use one AWS region. Database pods represent the VM backends for this demonstration. This is not a production HA design.

## Current result, 2026-10-12

Offline checks and ARM image builds passed. AWS provisioning failed before workload installation. Ireland had five allocated Elastic IP addresses and a quota of five. The NAT gateway could not obtain an address. Worker bootstrap then timed out when it contacted AWS APIs. No worker joined EKS. No CNG scenario ran on AWS. The proposed small-worker resource fit is not yet measured.

A quota check now stops a cold launch before Terraform creates billable resources when no address is available. Existing addresses and other environments are not changed. The partial deployment was deleted on 2026-10-12 after explicit authorization. Terraform removed 72 tracked resources. Live checks confirmed that the EKS cluster, VPC, worker instances, volumes and network interfaces were absent. All five existing Elastic IP allocations remained. The disabled encryption key is scheduled for deletion on 2026-11-11, after the AWS deletion window. Private state and cleanup evidence remain locally. Do not treat this demo as ready until live validation completes.

## Topology

| Worker pool | Count | Type | Workloads |
|---|---:|---|---|
| Primary | 2 | m7g.large | Three data pods and two index/query pods |
| Secondary | 1 | m7g.large | One data/index/query pod |
| Applications | 2 | m7g.large | Four CNG pods, two Observers, Envoy and Java clients |

CNG has two replicas per cluster and runs in separate Deployments. It is not an Operator sidecar. Anti-affinity places each gateway pair on different application workers. Headless Services expose individual gateway addresses to Envoy. The primary and secondary use different priorities.

The backend configuration keeps the Compose test settings: Server EE 8.0.3, CNG 1.2.1, a 512 MiB bucket, primary replica count one, secondary replica count zero, auto-failover timeout 30 seconds and maximum count 100. Index/query services are available on both clusters. No XDCR is configured.

## Prerequisites

Use an AWS profile with permission to create the isolated demo resources. Install AWS CLI v2, Docker, Helm and Python 3. The script can download checksum-verified Terraform 1.16.5 and a kubectl version compatible with EKS 1.35 into private local storage. It does not replace system tools.

The account needs one free Elastic IP address for the NAT gateway. The script does not increase account quotas or reuse another environment's address. Five on-demand ARM workers must also be available in the selected region.

## Lifecycle commands

Run commands from the repository root. Replace the profile placeholder with the approved sandbox profile.

```bash
hack/cng-aws-demo.sh --plan --profile <profile>
hack/cng-aws-demo.sh --up --profile <profile>
hack/cng-aws-demo.sh --status --profile <profile>
hack/cng-aws-demo.sh --validate --profile <profile> --gateway-replicas 1
hack/cng-aws-demo.sh --reset --profile <profile>
hack/cng-aws-demo.sh --validate --profile <profile> --gateway-replicas 2
hack/cng-aws-demo.sh --scenario 2 --profile <profile>
hack/cng-aws-demo.sh --scenario 3 --profile <profile>
hack/cng-aws-demo.sh --reset --profile <profile>
hack/cng-aws-demo.sh --park --profile <profile>
hack/cng-aws-demo.sh --destroy --profile <profile>
```

`--up` creates or resumes the owned environment. It first creates both databases and seeds the indexes and markers. It then starts CNG and the Observers. Finally it renders the Observer Service addresses into Envoy. The script builds images from the selected source commit and uses private ECR image digests.

`--reset` is an explicit operator action. It exports evidence before changing the test state. It is not automatic crash recovery. `--park` hibernates the databases and scales workers to zero. EKS, NAT and storage charges continue. `--destroy` exports workload evidence, removes the Kubernetes resources and PVCs, removes the Terraform resources, and checks the owned resource inventory. Local evidence remains. Destruction must be explicitly authorized when an agent executes it.

`--name` can select a separate name that starts with `cng-demo`. `--region` defaults to `eu-west-1`. Local ownership records prevent cross-account actions and adoption of an existing cluster without state. Do not delete the private state directory while AWS resources remain.

## Verification and evidence

```bash
DEMO_PYTHON=<venv-python-with-pyyaml> test/aws/cng-demo/render.sh
python3 test/aws/cng-demo/control_test.py
python3 test/aws/cng-demo/runner_test.py
python3 test/aws/cng-demo/lifecycle_test.py
TERRAFORM=<terraform-binary> python3 test/aws/cng-demo/infra_test.py
```

Runtime evidence is stored under `.demo-aws/<name>/evidence/`. State, credentials, certificates and kubeconfig are private and ignored by Git and Docker. Do not publish this directory. Export logs are redacted using the generated demo password. CNG 1.2.1 can log backend credentials, so inspect any artifact before external sharing.

Validation ports scenarios 1 through 8 and 10 plus readiness from Compose. DNS scenario 9 remains deferred. Positive clients must establish current-run transport and data readiness before faults. KV deadlines remain two seconds and query deadlines remain five seconds. Each operation needs sustained terminal recovery. Region attribution comes from GET/query markers; write placement remains unobserved.

The single-gateway profile is for comparison with Compose. The fleet profile also checks direct operations through every gateway, new Envoy connections to every primary endpoint, and a planned loss of one primary gateway. Direct probes are labeled and do not count as evidence of Envoy routing. Multiple connections do not prove equal request throughput.

Any unexpected CNG restart, termination or replacement fails the run, even if another gateway keeps traffic working. Client pods must not restart or be replaced during a fault. Diagnostics retain Pod identities, exit/OOM states, previous logs, events, node resource statistics, fault timestamps, Observer responses, Envoy state and CSV files. Failed writers are stopped before partial evidence is exported. A diagnostic failure does not replace the original fault result.

## Limits

CNG panic paths and the combined gateway/data-path health policy remain unresolved. A database Observer cannot detect every gateway failure. CNG HTTP 200 does not prove that its backend is available. Kubernetes endpoint discovery and process readiness do not prove complete data-path health.

The static priority configuration can split old and new clients after primary recovery. Coordinated failback is not implemented. Availability does not prove data continuity. This demo does not test actual AWS-region loss, worker-host HA, mTLS, production load, or the one-hour idle expiry.

Cold launch and park/resume times must be measured after the AWS blocker is removed. No verified launch-time promise is made for this deployment.
