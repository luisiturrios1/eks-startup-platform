# Local plan execution evidence

Executed on 2026-10-18 (America/Mexico_City), macOS ARM64. This is local emulator evidence, not AWS deployment acceptance.

## Tools and boundaries

- Terraform 1.16.6; AWS provider 6.69.1; Helm provider 2.17.0. Both new root locks include verified darwin_arm64 and linux_amd64 checksums.
- MiniStack 1.5.27, using the pinned image in `local/plan.compose.yml`, account `000000000000`, loopback endpoint `http://127.0.0.1:14566`. No Docker socket was mounted.
- kind 0.33.0 with pinned Kubernetes node image v1.34.0; explicit context `kind-platform-review`.
- The infrastructure and Kubernetes roots use separate local backends; each regional plan has its own backend path and Terraform data directory. The `default` workspace was verified.
- Synthetic account/certificate/IdP/image/DNS fixtures only. No AWS credentials, AWS state access, state migration, Terraform apply or destroy.

## Commands and captured summaries

Started the dedicated emulator and kind cluster using the commands in the [README](../../README.md#run-locally-without-aws-credentials), then executed:

```bash
PATH="$PWD/.artifacts/bin:$PATH" .venv/bin/python scripts/local_plan.py
```

The runner initialized with read-only locks, validated each target, saved the plan, read that same saved plan with `terraform show` in text and JSON, and inspected its resource changes. The following lines were captured from successful executions:

```text
Target: us-east-1
Plan: 213 to add, 0 to change, 0 to destroy.
Reviewed plan: us-east-1 {'create': 213}

Target: us-west-2
Plan: 213 to add, 0 to change, 0 to destroy.
Reviewed plan: us-west-2 {'create': 213}

Target: kubernetes
Plan: 1 to add, 0 to change, 0 to destroy.
Reviewed plan: kubernetes {'create': 1}

```

The 213 regional resources include the existing RDS/cache/network/operations extensions, not just EKS and IAM. No resource was created by these Terraform plans. The Kubernetes plan proposes one Helm release, whose chart renders two Namespace objects.

| Region | Planned cluster name | AZ fixtures | VPC CIDR |
|---|---|---|---|
| us-east-1 | review-us-east-1-dev | `["use1-az1", "use1-az2", "use1-az3"]` | `10.40.0.0/16` |
| us-west-2 | review-us-west-2-dev | `["usw2-az1", "usw2-az2", "usw2-az3"]` | `10.50.0.0/16` |

Both plans contain these create operations, verified from their saved-plan JSON:

```text
module.platform.aws_eks_cluster.this
module.platform.aws_eks_node_group.system
module.platform.aws_iam_role.runtime["payments-service"]
module.platform.aws_iam_role_policy.runtime["payments-service"]
module.platform.aws_s3_bucket.service["payments-service"]
```

## Selected saved-plan output

The following complete resource block is excerpted from the actual east-region `terraform show` output:

```hcl
  # module.platform.aws_eks_cluster.this will be created
  + resource "aws_eks_cluster" "this" {
      + arn                           = (known after apply)
      + bootstrap_self_managed_addons = true
      + certificate_authority         = (known after apply)
      + cluster_id                    = (known after apply)
      + created_at                    = (known after apply)
      + deletion_protection           = (known after apply)
      + enabled_cluster_log_types     = [
          + "api",
          + "audit",
          + "authenticator",
          + "controllerManager",
          + "scheduler",
        ]
      + endpoint                      = (known after apply)
      + id                            = (known after apply)
      + identity                      = (known after apply)
      + name                          = "review-us-east-1-dev"
      + platform_version              = (known after apply)
      + region                        = "us-east-1"
      + role_arn                      = (known after apply)
      + status                        = (known after apply)
      + tags                          = {
          + "CostCenter" = "local-evaluation"
          + "Owner"      = "platform-review"
        }
      + tags_all                      = {
          + "CostCenter"  = "local-evaluation"
          + "Environment" = "dev"
          + "ManagedBy"   = "Terraform"
          + "Owner"       = "platform-review"
          + "Project"     = "review-us-east-1"
        }
      + version                       = "1.35"

      + access_config {
          + authentication_mode                         = "API"
          + bootstrap_cluster_creator_admin_permissions = false
        }

      + compute_config (known after apply)

      + control_plane_scaling_config (known after apply)

      + encryption_config {
          + resources = [
              + "secrets",
            ]

          + provider {
              + key_arn = (known after apply)
            }
        }

      + kube_api_server_config (known after apply)

      + kube_controller_manager_config (known after apply)

      + kube_scheduler_config (known after apply)

      + kubernetes_network_config {
          + ip_family         = "ipv4"
          + service_ipv4_cidr = (known after apply)
          + service_ipv6_cidr = (known after apply)

          + elastic_load_balancing (known after apply)
        }

      + storage_config (known after apply)

      + upgrade_policy (known after apply)

      + vpc_config {
          + cluster_security_group_id = (known after apply)
          + control_plane_egress_mode = (known after apply)
          + endpoint_private_access   = true
          + endpoint_public_access    = false
          + public_access_cidrs       = (known after apply)
          + security_group_ids        = (known after apply)
          + subnet_ids                = (known after apply)
          + vpc_id                    = (known after apply)
        }
    }
```

The API endpoint is private, cluster creator administration is disabled, control-plane audit logs are enabled, and Kubernetes secrets encryption references the platform key. IDs and ARNs remain unknown until creation; local planning does not prove AWS authorization or EKS availability.

The actual namespace chart was also rendered and tested for `auth-service` and `payments-service`, restricted Pod Security labels, and `helm.sh/resource-policy: keep`. Namespace ownership is Terraform-managed through Helm; no namespace release was installed. Existing deployments require the [ownership review](../deployment.md#application-namespace-ownership).

## Executed verification

| Command/check | Result |
|---|---|
| `PATH="$PWD/.artifacts/bin:$PATH" scripts/validate.sh` | Passed: format, dev/staging/prod contracts, repository policy, nine backend-disabled root initializations/validations, Python tests, mocked plans, five Helm charts and private controller image checks. |
| `.venv/bin/python -m pytest -q tests` | 55 passed; ten opt-in cases skipped in the default run. |
| `terraform -chdir=modules/platform test` | Six mocked plans passed, including emitted-policy checks for write-only access. |
| `terraform -chdir=kubernetes/dev test` | Six mocked plans passed, including contract-derived namespaces. |
| Controlled IAM regression in a temporary copy | Replacing the emitted `s3:PutObject` action with `s3:*` caused the write-only assertion to fail as expected. The repository source was not mutated for this negative test. |
| `PLATFORM_ADMISSION_INTEGRATION=1 KUBEBUILDER_ASSETS=... .venv/bin/python -m pytest -q tests/test_admission.py` | Seven passed against an isolated node-free local API. Processes were stopped by the test fixture. |
| `.artifacts/bin/tflint --recursive` | Passed. |
| `uv tool run --python 3.12 checkov -d . --framework terraform --compact -o json` | 536 passed, zero failed, 41 existing scoped exceptions, zero parsing errors. |
| Configured Trivy HIGH/CRITICAL scan and `scripts/scan_manifests.sh` | Passed with existing documented exceptions. The namespace chart is included. |
| `.artifacts/bin/gitleaks dir . --redact --config .gitleaks.toml` | No leaks detected in the directory scan. This is not a full Git-history audit. |
| `scripts/estimate_costs.py` | Completed for dev, staging and prod; partial estimates retain existing coverage limits. |
| `git diff --check` | Passed. |

The mocked Terraform tests are separate from the API-backed regional plans. The seven admission cases were executed separately from the default test run. The three Docker/database integration cases and Maven/application suites were not rerun: no Java, database credential lifecycle, SQL, or application image changed. The new hosted Linux AMD64 CI job has been added but was not executed from this workspace.

## Cost and deployment review

The refreshed default-region Infracost results are partial, unadjusted example estimates: dev $1,078.28/month, staging $1,078.28/month, prod $1,231.81/month. Each has 79 usage components without quantities and one missing price; the known MySQL 8.4 pricing-model limitation remains. These are not quotes for the two review regions. See [coverage details](../cost.md).

This change adds no billable AWS capacity to the existing environments: it narrows runtime storage permissions and adds a namespace-only Helm release. Applying the synthetic regional fixture platforms would be a separate, inappropriate use of these plan-only inputs; actual AWS deployment needs authorized real inputs and reviewed environment plans. Existing namespaces require a reviewed ownership transition, and callers relying on removed S3 read/list capabilities require review.

All initial local plans are create-only, with no update, delete or replacement. Existing-environment drift, replacements and deletions remain unknown without those environments' plans. The plans do not establish AWS IAM denial behavior, private network packet paths, WAF enforcement, managed failover or recovery targets.

Full plans and text/JSON-derived summaries remain in ignored, access-restricted `build/local-plan/`. This document contains only reviewed non-secret evidence; no binary plan or state snapshot is included.

The dedicated review kind cluster and Compose emulator/network were removed after validation. Existing `platform-local` containers were preserved. The active kubeconfig context was set to the existing `kind-platform-local` context after removing the temporary context. Saved plans remain available locally; restarting the dedicated review resources is required to rerun the plan workflow.
