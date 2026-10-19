# Operator deployment and recovery runbook

No command here has been executed against AWS. Obtain explicit environment authorization and review security/cost implications before applying any plan. Never use automatic approval. GitHub Actions only validates.

## Prerequisites and bootstrap

1. Select distinct production/non-production accounts, three stable AZ IDs, non-overlapping VPC/VPN CIDRs, ownership/cost tags, budget and alert recipients. The current subnet layout uses an IPv4 `/16` VPC. Activate billing cost-allocation tags for Environment, Project and CostCenter.
2. Supply a federated deployment/admin role with short-lived credentials, a SAML provider whose administrator group requires MFA, an ACM VPN server certificate, regional ACM HTTPS certificate and public Route53 zone. Terraform does not generate private keys or configure the external IdP.
3. Bootstrap once per account using `bootstrap/`, with a unique state bucket name. Review its plan before an authorized apply. It creates state protection, CloudTrail management/state-object logging and a private `platform-artifacts` ECR repository. The initial local state is sensitive and ignored. Migrate it into the encrypted remote backend only under separate explicit authorization and a recovery copy; there is no automatic migration script.
4. Grant operator state access only to the appropriate prefix (`ListBucket` prefix condition, Get/Put state, Get/Put/Delete `.tflock`, KMS encryption/decryption). State readers must not automatically gain deployment rights. Restrict production access through account federation and IAM. Do not distribute state snapshots as application configuration.
5. Run `scripts/prepare-assets.sh`. Review third-party chart manifests and image provenance. Mirror controller images and the built application/credential-manager images into private ECR with immutable digests. Build AWS images for `linux/amd64`; the bootstrap registry must already contain the credential-manager image before the infrastructure plan is applied. No targeted partial apply is required.

## Infrastructure

Copy `terraform.tfvars.json.example` to ignored `terraform.tfvars.json` in the selected root and replace all placeholders. Update service image digests and environment database groups, then compile:

```bash
.venv/bin/python scripts/compile_services.py --environment dev
.venv/bin/python scripts/preflight.py --environment dev --vars environments/dev/terraform.tfvars.json
terraform -chdir=environments/dev init -backend-config=backend.hcl
terraform -chdir=environments/dev workspace show
terraform -chdir=environments/dev plan -out=review.tfplan
terraform -chdir=environments/dev show review.tfplan
```

Create ignored `backend.hcl` from its example before initialization. Verify expected account, region, backend bucket/key and default workspace. Use separate directories/states rather than workspaces for isolation. Review deletions, replacements, permissions, public exposure, costs and drift. An operator applies only the reviewed saved plan after explicit approval. Keep plans local with restricted permissions and delete them after review/use.

Regional preflight checks AZs, endpoint services, engine offerings and EKS add-on versions. Set exact approved versions after reviewing the available regional choices. It also checks account and CIDR boundaries. Confirm quotas, ACM ownership/region, DNS, VPN certificate validity and IdP MFA manually. Regional availability does not guarantee capacity or quotas.

The infrastructure root may contact public AWS **management** APIs from the operator machine; application traffic inside the VPC has no Internet route. EKS nodes and services use VPC endpoints. S3 gateway destinations retain AWS public IP ranges while routing over the private gateway; a public DNS/IP alone does not demonstrate Internet transit.

## Kubernetes and services

1. Connect the administrator Client VPN. Confirm private API connectivity and expected IAM principal. Bootstrap EKS kubeconfig for the exact cluster/region.
2. Export `terraform output -json platform` to an ignored `build/<environment>/infrastructure.json`, then run `scripts/export_values.py FILE --environment ENV`. This produces non-secret platform/service inputs. Keep credentials and secret values out of outputs.
3. Populate Kubernetes root image digests, pinned AMI ID, reviewed `managed_addon_images` inventory and backend. Follow [workload security inputs and rollout](workload-security.md) before enabling registry admission or upgrading managed add-ons. Supply exported platform values using `-var-file`; review and authorize that root's plan. It first installs the native registry-admission guardrails, then the `platform-network` bootstrap chart in the existing/created `cert-manager` namespace. This chart contains only NetworkPolicy objects and needs no working cluster DNS or admission webhook. Managed CoreDNS is then installed, followed by cert-manager, Karpenter, the restricted TargetGroupBinding controller, metrics-server and telemetry. Telemetry policies are installed with the platform chart. Strict VPC CNI enforcement stays enabled throughout. The post-renderer rejects foreign-account/region, public or unpinned controller images, including inline Helm hooks. Native admission enforces the same image boundary for all Pods, with exact reviewed AWS-managed exceptions.
4. Invoke the credential manager explicitly with `{"action":"bootstrap"}` after reviewing the environment and function name. This creates only service-scoped database users/secrets, not application schemas. Scheduled rotation uses alternating users and retains previous credentials during handover.
5. Run `scripts/deploy-service.sh --approved VALUES.json EXPECTED_KUBECTL_CONTEXT` only after approving the application release. Initial prerequisites are installed before the separate migration release. A failed migration stops rollout; existing workloads are retained. Inspect and fix forward rather than automatically reversing schema changes.
6. Confirm certificate readiness, target-group health, VPN access restrictions, telemetry and the AWS acceptance checklist below. Confirm email alarm subscriptions.

Applications poll their secret every minute, validate a replacement pool, switch traffic and retire the previous pool after a grace period. Rotation failures retain current credentials and pending versions for retry; CloudWatch alarms and the DLQ require operator attention. PostgreSQL database ownership is distinct from alternating login roles.

## Upgrading an existing deployment

This release changes CoreDNS state ownership and cache resource addresses. Do not apply either root to an existing deployment until the corresponding plans and the following recovery steps have been reviewed. No state operation is automated or authorized by this runbook.

### CoreDNS ownership transfer

The old address is `module.platform.aws_eks_addon.runtime["coredns"]` in the infrastructure state; the new address is `aws_eks_addon.coredns` in the Kubernetes state. Existing infrastructure plans intentionally fail the deletion safeguard while the old address remains. Do not remove that safeguard to force deletion/recreation.

1. Obtain explicit authorization for the environment and cross-root state transfer. Verify both account/backend/workspace identities, pause concurrent operator runs and prepare access-restricted recovery copies of both remote states, including their version identifiers. Never commit or publish these copies.
2. Prepare the Kubernetes inputs with the expected account, approved CoreDNS version and actual service CIDR verified through read-only STS/EKS queries; old saved outputs do not yet contain these new fields. Install the new bootstrap policy release through a reviewed Kubernetes-root plan before transferring ownership. Existing EKS-managed CoreDNS must remain running. A first-install plan at the new address must not be applied over an already managed add-on; use a separately reviewed, explicitly authorized bootstrap-only operation if policies are not already installed (plan only `helm_release.network`, inspect its scope, and obtain approval before applying the saved plan).
3. Under the approved state-transfer procedure, remove the old state ownership without destroying the add-on, then adopt the same existing `CLUSTER:coredns` add-on at the new address. Such state removal/import requires its own explicit authorization; never run it as a deployment side effect. Record the identifiers and state versions before and after the transfer.
4. Re-export infrastructure outputs, including account ID, service CIDR and approved CoreDNS version. Review both complete plans: the add-on must have exactly one state owner and no destroy/recreate operation. Inspect any version update separately, then authorize the intended deployment.
5. If transfer fails, stop deployment. With operator authorization and locked, verified backends, restore the previous ownership using the recovery copies/version identifiers, ensuring only one root owns CoreDNS. Do not delete the live add-on. Confirm DNS and controller health before releasing the change freeze.

New deployments need no state transfer: infrastructure creates the nodes and Pod Identity agent, then the Kubernetes root installs the allow policies before CoreDNS or controllers. The three Kubernetes roots now also pin the AWS provider and restrict it to the exported account ID. Kubernetes AWS management calls run from the operator machine; workload network isolation does not change.

### Cache address changes and retirement

`moved` blocks preserve the subnet group, disabled default user, user group, replication group and memory alarm when their addresses gain `[0]`. When a consumer remains, the expected plan contains address moves rather than cache replacement. Service user addresses remain stable.

When all services set `permissions.cache=false`, a new environment creates no managed cache resources. For an existing cache, `prevent_destroy` intentionally blocks removal or replacement of the replication group. Before an explicitly authorized retirement: verify no clients remain, stop cache writes, decide whether data is disposable or must be retained, create and verify the approved backup/snapshot and retention period, and document a tested restore/endpoint rollback path. Keep at least one consumer configured until that review is complete. Only then authorize a separate change to the deletion safeguard and review the full removal plan. Re-adding consumers after removal creates a new cache; Terraform does not restore data automatically.

### Leaf TLS renewal

The application PEM bundle opts into reload and uses explicit filesystem resource locations. Its test swaps Kubernetes-style `..data` certificate/key symlinks atomically and verifies a new serial over a hostname-validated TLS connection without restarting Tomcat. The telemetry receiver also reloads its certificate/key every minute. Live acceptance must confirm projected Secret updates and served serials for application and telemetry endpoints. Root CA replacement still requires the trust-distribution/rollover procedure below.

## AWS acceptance and recovery

- From outside VPN, EKS API must be unreachable; inside VPN only authorized IAM identities may administer it.
- From representative pods, verify secrets, ECR pulls, S3, logs/traces and cache work; arbitrary Internet egress must fail. Inspect route tables, endpoint policies and flow logs.
- Verify each service is denied another service's secret, bucket, database and cache prefix. Emulator IAM tests cannot replace these checks.
- Generate WAF test requests and confirm blocking and redacted logs. Verify ALB TLS and HTTPS targets.
- Exercise HPA and Karpenter scale-up/down within limits; drain nodes and check PDB behavior. Verify CloudWatch/X-Ray data and alarms.
- Test credential rotation/retry with a running workload and failed migration blocking rollout.
- Restore an RDS backup into a separately approved temporary instance, validate data and measure actual RTO/RPO. Test managed Multi-AZ failover under an approved maintenance exercise. Do not claim contractual recovery targets until measured.
- For database/group/engine changes, copy/replicate into a new target, validate, cut over and retain rollback data. Never change state manually to fake a data migration.
- Before changing internal CA trust, distribute the new CA, restart clients/collectors, rotate leaf certificates, then retire the old CA. Cert-manager leaf renewal alone is not a complete root rollover procedure.

No production shutdown scheduling, cross-region replication or live provisioning tests run by default. Teardown of persistent data requires explicit authorization, reviewed final snapshots and removal of deletion safeguards through a separately reviewed change.

## Image promotion details

Application builds and execution use Java 26. Rebuild the complete application image; changing only its runtime tag does not migrate the compilation target. Follow the [Java 26 release and rollback checklist](java26.md), including the end-of-support review, before approving promotion. Both services and their migration Jobs share the new image and must be validated together.

`config/images.lock.json` records upstream controller and base-image digests. Authenticate skopeo to the bootstrap ECR registry using short-lived operator credentials. `scripts/mirror_images.py --repository ACCOUNT.dkr.ecr.REGION.amazonaws.com/platform-artifacts` prints the proposed copies without pushing. Adding `--approved` performs explicit promotion, preserves multi-architecture digests, verifies destination digests, and writes ignored `build/images.auto.tfvars.json`. Pass that file to the Kubernetes root together with exported platform inputs.

Application and credential-manager images are built locally from their Dockerfiles, scanned, and explicitly pushed by the operator. Their resulting ECR digests populate the service contracts and infrastructure `rotation_image_uri`. Never substitute mutable image tags or a public repository to work around private cluster connectivity.
