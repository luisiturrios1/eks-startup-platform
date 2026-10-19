# Workload security requirements

This assessment covers repository configuration, not a deployed AWS cluster. EKS is the compute service; private container registries are Amazon ECR. The registry boundary is the environment's account **and** region. The requester explicitly allowed AWS-managed EKS add-ons to retain their AWS ECR images; this exception does not extend to third-party controllers or application images.

| Requirement | Previous behavior | Implemented behavior |
|---|---|---|
| Only approved registry images can run | Terraform and the Helm post-renderer accepted any private ECR account; direct Pod creation had no registry admission control | Native `ValidatingAdmissionPolicy` with `failurePolicy: Fail` and a `Deny`/`Audit` binding validates every Pod creation/update and the ephemeral-container subresource, in every namespace |
| Third-party Helm/runtime images use owned ECR | Controller mirrors and pinned digests existed, but the post-renderer used line matching and did not bind to the environment | Terraform validates the account, region and digest; structured YAML inspection checks inline manifests, init containers and Helm hooks. Chart tag-plus-digest syntax is normalized to the same digest without a mutable tag |
| Pod communication requires explicit network policy | Strict VPC CNI and namespace ingress/egress denial already existed; dependency rules selected whole namespaces | Dependencies and reverse caller rules now select the named application's runtime pods on TCP 8443. Migration Jobs cannot inherit runtime-to-runtime access. Telemetry targets select the collector. An empty caller/edge list produces no ingress grant |
| Each service has its own ServiceAccount and least-privilege IAM role | Each namespace already had separate `runtime` and `migration` accounts, roles and Pod Identity associations, with permissions on owned resources | Trust also requires the exact `kubernetes-namespace` and `kubernetes-service-account` request tags, in addition to the existing cluster/account conditions. Terraform rejects mismatched service map keys and names |

The Kubernetes account identity is namespace plus name: `auth-service/runtime` and `payments-service/runtime` are different identities. Automatic Kubernetes API token mounting remains disabled. Pod Identity supplies short-lived AWS credentials separately. Runtime policies read only the service runtime secret and explicitly owned additional secrets, and grant bucket/cache operations only when declared. Migration policies read only their own migration secret and decrypt through Secrets Manager. No new application IAM action or cross-service grant was added.

## Registry admission and the AWS-managed exception

`charts/guardrails` creates only native admission objects, with no extra controller, webhook, container image or billable AWS resource. Every Kubernetes root installs it before network bootstrap/CoreDNS and third-party Helm controllers. The Helm release has a deletion safeguard. The policy covers normal containers, init containers/native sidecars, ephemeral debug containers and OCI image volumes. Own-registry references must be canonical `REGISTRY/REPOSITORY@sha256:DIGEST` values. Direct `kubectl`, Helm hooks, custom operators and Jobs all reach the same Pod admission boundary; a Deployment object may be accepted while its disallowed Pods are rejected.

The exception is the intersection of:

1. Namespace `kube-system`.
2. The exact add-on ServiceAccount: `aws-node`, `kube-proxy`, `coredns` or `eks-pod-identity-agent`.
3. An exact image reference in the reviewed `managed_addon_images` input for that account.

There is no blanket `kube-system`, registry-prefix, namespace-label or administrator bypass. Even an exempt add-on account cannot run an arbitrary AWS ECR image. Debug containers and OCI image volumes always require owned ECR. Managed add-on version tags are an explicit exception to the digest requirement; wildcard images and mutable aliases such as `latest` are rejected by input validation. Application and third-party images have no such exception.

Only trusted platform administrators should be able to modify admission policies/bindings, namespace labels, NetworkPolicies, Pod Identity associations or workloads in system namespaces. Application accounts receive no Kubernetes RBAC grants from these charts. Cluster administrators and node/root access remain privileged trust boundaries; admission cannot police a compromised host or a static container launched outside the API server.

## Operator inputs and rollout

Use the existing per-account bootstrap ECR repository for mirrored controllers. `scripts/mirror_images.py` continues to print proposed copies unless explicitly run with `--approved`; no promotion was performed for this change. Build/scan/promote application and credential-manager images separately and supply their resulting own-account/regional digests. The repository's illustrative service images intentionally remain non-deployable.

For an existing cluster, first export fresh `terraform output -json platform` after reviewing the new output-only infrastructure change. Verify backend, workspace, account, region and the expected Kubernetes context. With approved read-only AWS/Kubernetes access, capture the existing managed add-on templates:

```bash
.venv/bin/python scripts/export_addon_images.py \
  build/ENV/infrastructure.json --context EXPECTED_CONTEXT \
  > build/ENV/managed-addons.auto.tfvars.json
```

The helper verifies STS account, the EKS endpoint, Kubernetes context endpoint, all four ACTIVE managed add-ons, expected versions and ServiceAccounts. It collects both regular and init-container images. **Review this inventory against the AWS-owned regional repositories and approved add-on builds before passing it to Terraform.** It is a read-only template inventory, not independent attestation of image provenance or running Pod compliance. No secret values are read or exported.

For a new cluster, CoreDNS may not exist yet because its installation follows admission/network bootstrap. Supply its exact reviewed regional AWS image reference, along with the CNI, network-policy agent, kube-proxy and Pod Identity images, from an approved matching add-on release inventory. The inventory helper intentionally refuses missing/not-ACTIVE add-ons; it does not install them or invent references. These inputs are a deployment prerequisite. Refresh/verify the live inventory after bootstrap.

Pass the reviewed inventory with `-var-file` to the Kubernetes root, together with the exported platform, mirrored-image and AMI inputs. Review its actual plan before authorization. Expected changes are one new guardrail Helm release per environment, controller release input changes, narrower service NetworkPolicies on the next service release and in-place runtime/migration IAM trust updates. No AWS capacity increase, data/schema migration or planned resource removal is introduced by this patch; only an actual environment plan can establish replacements, drift or deletions.

Before a managed add-on upgrade, review the next version's complete image set, including init containers and the CNI network-policy agent. Temporarily include both exact old and new references, update admission first, then perform the separately authorized add-on upgrade. Verify health and remove obsolete exceptions afterward. Updating the add-on version before approving its images can block replacement Pods, DNS, networking or Pod Identity. For a failed update, retain the last approved image inventory and follow the reviewed add-on rollback procedure; do not disable admission or broaden the exception to a namespace/registry.

Admission is not retroactive. Inventory existing Pods, controller templates and image volumes before enabling it; replace any non-compliant third-party/application workloads through an approved rollout. Existing Pods continue running, but their subsequent updates may be rejected. The AWS-managed infrastructure add-ons bootstrap before this separate Kubernetes root; the approved AWS exception covers those images. Confirm all other workloads are onboarded only after guardrails are active.

Changing IAM trust may deny incorrectly associated identities; test fresh credential sessions for both runtime and migration accounts. Existing issued sessions remain valid until expiration. Tightening network selectors can deny traffic from incorrectly labeled callers. Expected application paths require `dependencies` and the generated reverse `allowedCallers` values, plus matching `app`/`role: runtime` labels. Re-export service values so the actual Kubernetes service CIDR is included.

## Network and AWS acceptance boundaries

Service/system/telemetry namespaces retain default-deny ingress and egress. VPC CNI remains enabled in strict mode to avoid a startup allow window. Explicit DNS, private AWS endpoint, database/cache, Pod Identity, telemetry and approved ALB paths remain available. The S3 HTTPS rule excludes VPC/service CIDRs and link-local addresses; isolated route tables, endpoint policies and security groups enforce private transport to regional S3 addresses. NetworkPolicy alone does not restrict HTTPS to a dynamic S3 IP list or establish AWS IAM authorization.

AWS documents limitations for host-network system agents and supported VPC CNI Pod types. Restricted application namespaces must not run host-network/privileged workloads. Standard NetworkPolicy is additive: a privileged administrator can widen access by installing another policy. Local tests do not prove AWS CNI eBPF enforcement, endpoint routing, node access restrictions or actual IAM decisions.

Before deployment approval, verify native admission API availability and policy type-checking, dry-run rejection of foreign/public/untagged images (including init/debug containers), each exact AWS exception, owned controller mirrors, fresh Pod Identity sessions and cross-service AWS denial. Test denied same-namespace/cross-namespace flows and positive declared dependencies in AWS; verify DNS, TLS, ALB health, migration Jobs, telemetry and add-on recovery. No AWS plan, deployment, state operation or live AWS acceptance test was performed here.

## Cost and validation

This implementation adds no Pods, nodes, endpoints, load balancers or managed databases. Mirror storage/scanning/transfer and additional API audit events depend on actual usage; those incremental charges are unmeasured. Existing partial Infracost estimates remain unchanged; consult `cost.md` for missing usage/prices and exclusions. No precise incremental AWS bill is claimed.

Repository checks include formatting, backend-disabled Terraform validation for seven roots, all three environment contracts, mocked module/Kubernetes plans, Helm lint/render/private-image checks, image parsing and dependency isolation tests, and the configured security scanners. A separate node-free Kubernetes 1.35 API test uses upstream envtest binaries pinned by `config/envtest.lock.json` to exercise the actual rendered admission expressions, including Pod updates and ephemeral-container subresource requests. It starts only local loopback processes and cleans them up; it does not access the developer's kubeconfig, Docker or AWS.

```bash
.venv/bin/python scripts/prepare_admission_test.py
PLATFORM_ADMISSION_INTEGRATION=1 \
KUBEBUILDER_ASSETS="$PWD/.artifacts/envtest/controller-tools/envtest" \
.venv/bin/python -m pytest -q tests/test_admission.py
```

The ordinary test suite skips that opt-in API test and the existing Docker integration suites. Validation CI installs the checksum-pinned Linux AMD64 API binaries and runs the admission tests separately, without AWS credentials or Docker. See `validation.md` for executed checks and results.

Design references: [Kubernetes validating admission policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/), [AWS Pod Identity trust request tags](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html), [AWS VPC CNI network-policy requirements and limitations](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html), and [AWS add-on management](https://docs.aws.amazon.com/eks/latest/userguide/eks-add-ons.html).
