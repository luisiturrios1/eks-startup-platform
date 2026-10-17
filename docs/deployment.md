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
3. Populate Kubernetes root image digests, pinned AMI ID and backend. Supply exported platform values using `-var-file`; review and authorize that root's plan. It installs cert-manager, Karpenter, the restricted TargetGroupBinding controller, metrics-server and telemetry. The post-renderer rejects non-ECR or unpinned controller images.
4. Invoke the credential manager explicitly with `{"action":"bootstrap"}` after reviewing the environment and function name. This creates only service-scoped database users/secrets, not application schemas. Scheduled rotation uses alternating users and retains previous credentials during handover.
5. Run `scripts/deploy-service.sh --approved VALUES.json EXPECTED_KUBECTL_CONTEXT` only after approving the application release. Initial prerequisites are installed before the separate migration release. A failed migration stops rollout; existing workloads are retained. Inspect and fix forward rather than automatically reversing schema changes.
6. Confirm certificate readiness, target-group health, VPN access restrictions, telemetry and the AWS acceptance checklist below. Confirm email alarm subscriptions.

Applications poll their secret every minute, validate a replacement pool, switch traffic and retire the previous pool after a grace period. Rotation failures retain current credentials and pending versions for retry; CloudWatch alarms and the DLQ require operator attention. PostgreSQL database ownership is distinct from alternating login roles.

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

`config/images.lock.json` records upstream controller and base-image digests. Authenticate skopeo to the bootstrap ECR registry using short-lived operator credentials. `scripts/mirror_images.py --repository ACCOUNT.dkr.ecr.REGION.amazonaws.com/platform-artifacts` prints the proposed copies without pushing. Adding `--approved` performs explicit promotion, preserves multi-architecture digests, verifies destination digests, and writes ignored `build/images.auto.tfvars.json`. Pass that file to the Kubernetes root together with exported platform inputs.

Application and credential-manager images are built locally from their Dockerfiles, scanned, and explicitly pushed by the operator. Their resulting ECR digests populate the service contracts and infrastructure `rotation_image_uri`. Never substitute mutable image tags or a public repository to work around private cluster connectivity.
