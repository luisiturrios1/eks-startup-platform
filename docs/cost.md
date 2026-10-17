# Cost model and operating limits

**Infracost is configured for all three infrastructure roots. Actual monthly AWS spending remains unknown until workload usage and pricing coverage are reconciled.** The example `budget_usd` is an alert threshold input, not a price estimate or enforcement mechanism.

| Driver | Baseline / scaling behavior |
|---|---|
| EKS | One cluster per environment; control-plane hourly charge persists at zero application replicas |
| System compute | Two On-Demand system nodes; Karpenter capacity is additional and bounded by 32 vCPU / 128 GiB |
| VPC endpoints | 14 interface services × 3 AZs, plus endpoint data processing; S3 gateway is separate |
| VPN | Three subnet associations and connected-client usage |
| RDS | One instance per used domain group plus every dedicated service; two default groups; production Multi-AZ, gp3 storage with a 3× growth ceiling, backups and monitoring |
| ElastiCache | One managed Valkey deployment per environment; one non-production node, two production nodes plus snapshots |
| Edge | ALB hours/LCUs, WAF ACL/rules/requests, DNS queries and Internet egress |
| Observability | Logs ingestion, retention, CloudWatch metrics/alarms, X-Ray traces, VPC flow logs, RDS monitoring and CloudTrail events |
| Storage/security | S3 objects/noncurrent versions/access logs, ECR images/scanning, Secrets Manager API/secret charges, KMS requests/keys and Lambda rotation |
| Data transfer | Cross-AZ database/cache/backend traffic and inter-service calls; no NAT charge but interface endpoint costs remain |

## Local configuration

The native Infracost CLI is pinned to **0.10.46**, with reviewed SHA-256 checksums for macOS ARM64 and Linux AMD64 in `config/tools.lock.json`. Install only this tool with:

```bash
.venv/bin/python scripts/install_tools.py --tool infracost
```

Use the CLI's normal credential store (`~/.config/infracost/credentials.yml`, permissions `0600`, parent directory `0700`) or a securely supplied `INFRACOST_API_KEY` environment variable. Never put a key in Terraform, `infracost.yml`, a usage file, shell history or Git. Local credentials remain outside this repository. No AWS account access is needed.

```bash
.venv/bin/python scripts/estimate_costs.py
```

This validates and compiles service contracts for dev, staging and prod, reads each environment's JSON example, and writes complete ignored `build/infracost/ENV.tfvars.json` inputs. It then runs `infracost breakdown` using `infracost.yml`. This JSON conversion is required: passing `.json.example` directly makes this CLI parse it as HCL and silently substitute missing inputs.

The command rejects missing environment estimates and unresolved Terraform-input warnings, removes stale reports before a run, and writes:

- `build/infracost/costs.json`: unadjusted CLI output, coverage counts and resource cost components.
- `build/infracost/summary.md`: environment totals, unsupported-resource counts, missing prices and usage components without quantities.

To estimate operator-selected sizing, provide a private directory containing `dev.tfvars.json`, `staging.tfvars.json` and `prod.tfvars.json`:

```bash
.venv/bin/python scripts/estimate_costs.py --vars-dir /absolute/path/to/private/cost-inputs
```

Each file must identify the matching environment. Service/database definitions still come from `services/` and `config/`, preserving contract validation. Generated inputs and reports remain ignored; no state or saved Terraform plans are read. Infracost Cloud uploads are disabled for this command; the pricing API still receives cost-related parameters.

## Usage and model limitations

Review `config/infracost-usage/{dev,staging,prod}.yml` and fill in measured or explicitly approved workload assumptions. These files intentionally contain no invented usage values. Use resource addresses from `costs.json` and the [Infracost usage schema](https://www.infracost.io/docs/features/usage_based_resources/). Include storage/API requests, ALB/WAF traffic, VPN connections, logs, traces, backups and cross-AZ/Internet transfer as applicable. Missing usage is unknown, not free. Infracost applies its own defaults to some components and generally assumes 730 hours for provisioned monthly capacity.

The verified 2026-10-17 local run produced estimates for all three roots without missing Terraform variables. It reported 59 supported resources, two unsupported EKS access-entry resources, 79 usage components without quantities and one missing SNS component price per environment. Inspect every run's coverage because these counts can change.

**Known pricing-model issue:** CLI 0.10.46 matches MySQL `8.4` to its `8` extended-support rule and currently adds a $146/month extended-support component per example MySQL instance. AWS treats 8.4 as a separate supported major version. Raw totals are retained without silently changing the vendor output; reconcile this component against [AWS engine support dates](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MySQL.Concepts.VersionMgmt.html) before budgeting. The relevant matching logic is in the [pinned CLI source](https://github.com/infracost/infracost/blob/v0.10.46/internal/resources/aws/db_instance.go#L510).

The estimates cover the infrastructure roots and their local modules. Bootstrap resources and application capacity beyond the system node group, including Karpenter-managed EC2 instances, require separate estimation. Review data-source-derived values, unmodeled charges, discounts and taxes separately. These results are partial estimates, not a reviewed AWS deployment plan or a complete bill.

## GitHub Actions

`.github/workflows/infracost.yaml` runs on pushes to main, same-repository pull requests and manual dispatch. It reads `INFRACOST_API_KEY` from GitHub Actions repository secrets only in the estimation step. A missing key fails the trusted run instead of silently skipping estimation. Fork pull requests do not receive the secret and skip the estimation job.

The job installs the checksum-pinned CLI, runs the same local script, writes the Markdown report to the Actions job summary and uploads only `costs.json` and `summary.md` as `infracost-estimates`, retained for seven days. Generated tfvars and credentials are not uploaded. The workflow has only `contents: read`, no AWS credentials/OIDC permissions, and no apply/destroy, state access or pull-request commenting. The existing validation workflow no longer has a duplicate cost job.

Require the `Infracost / estimate` check in repository branch rules if cost estimation should block merges; no spending threshold is invented or automatically enforced.

Production keeps Multi-AZ data services and backups. Non-production can use smaller measured capacity, but the initial examples are not sized against a real workload. Domain sharing reduces instance count while retaining independent credentials; dedicated instances improve failure isolation at a higher baseline cost. A shared group with only one service still incurs a complete RDS instance charge.

There is no automatic shutdown policy, no Spot default and no cross-region replication. Confirm availability requirements before introducing any of them. Budget notifications require activated allocation tags and working email delivery; they do not stop resource creation.
