# Reusable EKS platform with least-privilege application access

This repository demonstrates a reusable Terraform platform: an EKS cluster, a managed node group, application namespaces, and application IAM roles scoped to owned resources. Two region fixtures produce inspectable plans without an AWS account. The local walkthrough exercises the **same platform module** used by the AWS environment roots.

Start with the local plans and IAM explanation below. The broader platform includes databases, cache, private networking and operational controls; [architecture details](docs/platform.md) and the [deployment runbook](docs/deployment.md) describe those extensions.

## Review map

| Requirement | Implementation | Evidence |
|---|---|---|
| EKS cluster and managed node group | [`modules/platform/main.tf`](modules/platform/main.tf), `aws_eks_cluster.this` and `aws_eks_node_group.system` | Saved-plan review for both regions |
| Application namespaces | [`charts/namespaces`](charts/namespaces), owned by Terraform `helm_release.namespaces` in the separate Kubernetes roots | Local Helm-provider plan and rendered Namespace objects |
| Application IAM role and policy | `aws_iam_role.runtime`, `aws_iam_role_policy.runtime` and Pod Identity associations in the platform module | Emitted-policy assertions and the explanation below |
| Regional reuse | [`us-east-1.tfvars`](examples/local-plan/infrastructure/us-east-1.tfvars) and [`us-west-2.tfvars`](examples/local-plan/infrastructure/us-west-2.tfvars) | Same root/module, distinct region, AZ IDs, CIDR and global names |
| Validation before merge | [GitHub Actions](.github/workflows/validate.yaml), Terraform tests, Checkov, Trivy and contract validation | [Executed evidence](docs/evidence/local-plans.md) |

## Run locally without AWS credentials

Prerequisites for the plan walkthrough:

- Terraform **1.16.6** was used; configurations require `>= 1.14, < 2.0`.
- Docker with Compose, Python 3.12+, and `kubectl` on `PATH`.
- kind 0.33.0 from the repository's checksum-pinned tool installer. The installer supports macOS ARM64 and Linux AMD64; other platforms need compatible tools installed separately.
- Internet access to download providers and the pinned emulator/kind images. No AWS account, AWS CLI, paid emulator token, Java installation or application build is needed for these plans.

The infrastructure root uses `hashicorp/aws ~> 6.0`; the namespace root uses `hashicorp/helm ~> 2.17`. Their committed `.terraform.lock.hcl` files pin the selected versions and checksums. Use the committed locks rather than updating providers during review.

From the repository root:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python scripts/install_tools.py --tool kind
export PATH="$PWD/.artifacts/bin:$PATH"
terraform version

# Dedicated plan-only emulator, on loopback; no Docker socket is mounted.
docker compose -f local/plan.compose.yml up -d --wait

# Dedicated namespace-plan cluster; existing platform-local resources are separate.
kind create cluster --name platform-review \
  --image kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a

# Compile service YAML against the schema, then plan and inspect all three roots/targets.
.venv/bin/python scripts/local_plan.py
```

The script runs `init -lockfile=readonly`, `validate`, `workspace show`, `plan`, and `show` for both regional infrastructure plans and the namespace plan. It verifies the emulator account is `000000000000`, checks the explicit kind context, and rejects updates, replacements or deletions in these fresh local plans. It never applies a plan. The namespace plan proposes one Helm release containing both service namespaces; the release has not been installed.

MiniStack replaces LocalStack to provide an account-free, token-free AWS API endpoint consistent with the repository's local stack. The plan root fixes every used AWS service endpoint to `http://127.0.0.1:14566` and supplies only disposable `test` credentials. The runner removes inherited AWS credentials/profiles and Terraform CLI argument overrides from its Terraform subprocesses. kind supplies the separate Kubernetes API. These are deliberate emulator substitutions, not claims of AWS equivalence; see [MiniStack's limitations](https://ministack.org/docs/limitations).

### Exact Terraform commands for each region

For reviewers who want to run Terraform directly instead of the runner:

```bash
.venv/bin/python scripts/local_plan.py --prepare-only
mkdir -p build/local-plan/us-east-1 build/local-plan/us-west-2 build/local-plan/kubernetes
chmod 700 build/local-plan build/local-plan/us-east-1 build/local-plan/us-west-2 build/local-plan/kubernetes
umask 077
export TF_DATA_DIR="$PWD/build/local-plan/us-east-1/.terraform-local"
terraform -chdir=examples/local-plan/infrastructure init -input=false -lockfile=readonly \
  -backend-config="path=$PWD/build/local-plan/us-east-1/terraform.tfstate"
terraform -chdir=examples/local-plan/infrastructure validate
terraform -chdir=examples/local-plan/infrastructure workspace show
terraform -chdir=examples/local-plan/infrastructure plan -input=false \
  -var-file=us-east-1.tfvars \
  -out=../../../build/local-plan/us-east-1/review.tfplan
terraform -chdir=examples/local-plan/infrastructure show \
  ../../../build/local-plan/us-east-1/review.tfplan

export TF_DATA_DIR="$PWD/build/local-plan/us-west-2/.terraform-local"
terraform -chdir=examples/local-plan/infrastructure init -input=false -lockfile=readonly \
  -backend-config="path=$PWD/build/local-plan/us-west-2/terraform.tfstate"
terraform -chdir=examples/local-plan/infrastructure validate
terraform -chdir=examples/local-plan/infrastructure workspace show
terraform -chdir=examples/local-plan/infrastructure plan -input=false \
  -var-file=us-west-2.tfvars \
  -out=../../../build/local-plan/us-west-2/review.tfplan
terraform -chdir=examples/local-plan/infrastructure show \
  ../../../build/local-plan/us-west-2/review.tfplan

export TF_DATA_DIR="$PWD/build/local-plan/kubernetes/.terraform-local"
terraform -chdir=examples/local-plan/kubernetes init -input=false -lockfile=readonly \
  -backend-config="path=$PWD/build/local-plan/kubernetes/terraform.tfstate"
terraform -chdir=examples/local-plan/kubernetes validate
terraform -chdir=examples/local-plan/kubernetes workspace show
terraform -chdir=examples/local-plan/kubernetes plan -input=false \
  -out=../../../build/local-plan/kubernetes/review.tfplan
terraform -chdir=examples/local-plan/kubernetes show \
  ../../../build/local-plan/kubernetes/review.tfplan
unset TF_DATA_DIR
```

Use the `default` workspace. Regional state paths are independent; the infrastructure and Kubernetes roots are also separate. This local-backend exception is restricted to disposable, plan-only fixtures. Real environment roots use encrypted, locked S3 state. Certificates, IdP, images and DNS in the fixtures are explicitly synthetic; these inputs are not AWS deployment instructions.

Generated contracts, plans, logs and state remain ignored under `build/local-plan/`. Saved plans can contain sensitive values: keep permissions restricted and do not upload them. The only committed `.tfvars` files are the two reviewed, non-secret regional fixtures. No real AWS credentials, real account configuration, secret values, state snapshots or binary plans are committed.

Stop only the dedicated review resources after inspection:

```bash
kind delete cluster --name platform-review
docker compose -f local/plan.compose.yml down
```

## Why the application IAM policy is minimal

Each service has a runtime role bound to its exact EKS cluster, namespace and `runtime` ServiceAccount through Pod Identity. It receives short-lived credentials. The node role does not hold application storage permissions. Migration jobs use a different identity and cannot pass their credentials to runtime pods.

The shipped `payments-service` and `auth-service` contracts request **write-only S3 access** because the example `/api/object` endpoint uploads an object. The permissions are generated from the schema-validated service contract, not supplied as arbitrary IAM JSON.

| Granted permission | Resource boundary | Reason |
|---|---|---|
| `s3:PutObject` | Only `arn:aws:s3:::<owned-service-bucket>/*` | Upload an object to that service's bucket |
| `kms:GenerateDataKey`, `kms:Decrypt` via regional S3 | Exact platform KMS key, constrained by `kms:ViaService` | SSE-KMS object writes with S3 Bucket Keys; KMS decryption does not grant S3 reads |
| `secretsmanager:GetSecretValue`, `DescribeSecret` | Own runtime credential secret and explicitly validated service-owned references | Refresh database credentials without storing their values in Terraform |
| `kms:Decrypt` via regional Secrets Manager | Exact platform KMS key, constrained by `kms:ViaService` | Decrypt the permitted Secrets Manager values |
| `elasticache:Connect`, only when requested | Exact replication group and service user | Authenticate to managed Valkey; its ACL further limits commands and key prefixes |

The object suffix `/*` covers objects **inside one named bucket**. It is not a wildcard grant to all buckets. The [AWS PutObject documentation](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html) explains S3/KMS permissions. IAM and the bucket policy must both permit a request; bucket policies require TLS and block public access.

Deliberately excluded from the shipped application roles:

- `s3:*`, `Resource = "*"`, other services' buckets, bucket administration, ACL changes, deletion and bucket listing.
- `s3:GetObject`: the demos do not download objects. A reviewed contract change to `permissions.s3: [read, write]` adds GetObject on the same owned bucket; it still adds no list/delete access.
- IAM management, `iam:PassRole`, EC2 provisioning, master database secrets, migration credentials and unrestricted KMS operations.

Controller roles are separate. Some AWS discovery and telemetry APIs require wildcard resources; those grants and the scoped scanner exceptions are explained in [security exceptions](docs/security-exceptions.md). They are not permissions of the application runtime role.

### How I would review a teammate's policy change

1. Map every action to an application call and every resource to ownership. Ask for the use case before accepting an additional capability.
2. Inspect the trust policy as well as permissions: cluster/account, namespace and ServiceAccount must remain exact. Compare runtime and migration access.
3. Review the actual rendered policy for resource boundaries, object-versus-bucket ARN scope, conditions, wildcard expansion, and indirect escalation through KMS or role passing.
4. Run schema checks, emitted-policy Terraform assertions and Checkov. Verify that a write-only contract cannot receive GetObject, ListBucket, DeleteObject or a wildcard grant.
5. Review the saved environment plan and investigate every IAM expansion, replacement, public endpoint or stateful deletion. In AWS, follow with authorized positive and cross-service-denial tests and audit-log inspection. Emulator success alone is insufficient.

## Design decisions and trade-offs

- **Reuse:** both regional fixtures call the existing first-party platform/network modules. No Terraform resource implementation is copied for the second region. Environment roots remain separate access and state boundaries.
- **Regional identity:** fixture project names include the region because IAM role names and S3 bucket names are not independently reusable within the same account simply by changing the provider region. AZ IDs and VPC CIDRs also differ.
- **State separation:** AWS infrastructure and Kubernetes configuration have independent roots. The local namespace plan uses kind; it does not pretend that a planned EKS endpoint already exists.
- **Namespace ownership:** Terraform owns a namespace-only Helm release, including restricted Pod Security labels. Application scripts require those namespaces. Existing deployments need an explicitly reviewed ownership transition; [the runbook](docs/deployment.md#application-namespace-ownership) covers the risk.
- **Private by default:** the shared module keeps EKS administration private, application subnets without NAT/default Internet routes, encrypted data, and service identities. Public HTTPS ALB plus WAF and administrator VPN are explicit edge boundaries.
- **Scope:** the module also includes RDS, Valkey and operational controls. The 213-resource regional plan includes those extensions; they are not necessary to demonstrate a minimal EKS/IAM exercise. Read the relevant module resources first rather than building the Java examples to inspect IaC.
- **Cost:** local planning creates no AWS billable resources. Deploying the extended platform would incur EKS, compute, endpoint, VPN, RDS/cache and observability costs. Existing Infracost estimates are partial, not a complete bill or a quote for two regions; see [cost coverage and limitations](docs/cost.md).

## Validation and evidence

[The committed evidence](docs/evidence/local-plans.md) records actual regional and namespace plan summaries, selected planned resources and the verification commands. It distinguishes emulator plans from Terraform mocked tests. No real AWS plan, apply, state migration, or deployment was performed.

To run the broader validation suite, install Helm 3 and the dependencies above, then:

```bash
.venv/bin/python scripts/install_tools.py
scripts/prepare-assets.sh
scripts/validate.sh
.artifacts/bin/tflint --recursive
uv tool run --python 3.12 checkov -d . --framework terraform --compact
.artifacts/bin/trivy config --ignorefile .trivyignore.yaml --exit-code 1 \
  --severity HIGH,CRITICAL --skip-dirs charts --skip-dirs .venv \
  --skip-dirs .terraform --skip-dirs .artifacts --skip-dirs examples/apps/target .
scripts/scan_manifests.sh
.artifacts/bin/gitleaks dir . --redact --config .gitleaks.toml
```

GitHub Actions runs validation and local plans without AWS provisioning credentials, OIDC deployment roles or apply/destroy jobs. The new local-plan job uses its own hosted runner; it does not share the application integration daemon. Checkov exceptions are resource-scoped and require review by 2027-01-16. A passing scanner is not proof that AWS IAM or networking behaves as intended.

## Further work and real AWS acceptance

Before deployment, supply authorized account/region/backend inputs, real private image digests, regional add-on/engine versions, ACM certificates, DNS and IdP configuration. Inspect actual plans and obtain approval. Verify Pod Identity, service isolation, endpoint paths, VPN restrictions, WAF, autoscaling, restore and failover in AWS; none is established by the local plans.

The Java 26/Spring Boot examples and their serial MiniStack/kind integration suites are optional for IaC review. Their setup is in [local development](docs/local.md). Temurin 26 is outside community support; production use requires the maintained runtime strategy described in [the Java release guide](docs/java26.md). The sample APIs are integration demos and have unauthenticated write endpoints.

For a live extension, start with the typed variables and service contract: add a second service without granting access to the first service's bucket, or extend the node-group interface with a reviewed taint/capacity configuration. Keep the change small, inspect the resulting plan, and explain the access or availability trade-off.
