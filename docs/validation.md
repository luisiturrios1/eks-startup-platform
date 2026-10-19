# Implementation validation

This records local evidence, not AWS deployment acceptance. The repository implements the AWS infrastructure, Kubernetes configuration, service contract, credential lifecycle, Java examples and validation-only CI described in README.

The sections dated 2026-10-17 and their Java 21 results are historical evidence for the previous release. The Java 26 migration supersedes that contract; see `java26.md` and the 2026-10-18 validation section below for the current change. Earlier passing checks do not establish Java 26 acceptance.

## Executed checks — 2026-10-17

| Check | Result |
|---|---|
| `PATH="$PWD/.artifacts/bin:$PATH" scripts/validate.sh` | Passed: Terraform 1.16.6 formatting, DSL compilation for all environments, repository policy checks, seven independent root initializations with backend disabled and validation, mocked Terraform tests, Helm lint/render and private controller image checks. |
| `.venv/bin/pytest -q tests` | 17 passed; 3 Docker integration tests intentionally skipped without their opt-in environment variable. |
| `terraform -chdir=modules/platform test` | 2 mocked plans passed, including services with optional bucket/cache permissions disabled; no AWS resources created. |
| `.artifacts/bin/tflint --recursive` | Passed. |
| `uv tool run --python 3.12 checkov -d . --framework terraform --compact -o json` | 538 passed, 0 failed, 41 resource-scoped skips, 0 parsing errors. Review `security-exceptions.md`; skips are not proof of security. |
| Trivy configuration scan, HIGH/CRITICAL, using `.trivyignore.yaml` | Passed with documented scoped exceptions. Lower-severity findings are not covered by this gate. |
| `.artifacts/bin/gitleaks dir . --redact --config .gitleaks.toml` | No leaks detected. |
| `examples/apps/mvnw -B -f examples/apps/pom.xml verify` | Passed with Flyway 11.20.3. Includes MiniStack Java Testcontainers integration, both service fixtures against PostgreSQL and MySQL, secret/S3 access, connection-pool credential refresh, migration locking and deliberate migration failure. The expected failed migration is a test assertion, not a build failure. |
| `PLATFORM_LOCAL_INTEGRATION=1 .venv/bin/pytest -q tests/integration` | 3 passed: database privileges and cross-service denial, credential rotation with overlap, Valkey key isolation. |

Local Maven used host Java 25 with Java 21 compilation target; the container build used Java 21, and CI explicitly installed Java 21 for that release. Helm CLI checks used Helm 4 locally; CI pins Helm 3.19.0 and the Terraform provider uses Helm 3. Private-image rendering checks account for the CLI post-render interface difference.

## Remaining acceptance and operational review

- No AWS plan, apply, destroy, state import, migration or live acceptance test was executed. Expected initial plans create the platform; inspect actual plans before authorization, especially IAM, public ingress, replacements and stateful resources.
- Supply real account IDs, stable AZ IDs, regional engine/add-on availability, SAML identity provider and MFA configuration, VPN certificates, DNS, ACM certificate, private ECR image digests and AMI selection. Example image references intentionally cannot deploy.
- Run the read-only regional preflight with authorized credentials. The current ARN and endpoint conventions target commercial AWS partitions; GovCloud and China are not validated.
- Verify VPN-only administrative access, endpoint packet paths and policies, AWS Pod Identity, managed RDS privileges/TLS and rotation, Valkey IAM authentication, CloudWatch/X-Ray delivery, WAF enforcement, failover and restore in AWS. MiniStack cannot establish these guarantees.
- Review resource-scoped scanner exceptions before deployment; their review deadline is 2027-01-16. Demo HTTP APIs illustrate integration and do not implement production payment processing or identity authentication.
- Database engine/group/placement changes require an explicit data migration and rollback plan. No automatic destructive migration is included.
- At initial implementation validation, the GitHub Actions workflow was inspected and its underlying checks run locally; a hosted run had not yet been observed. The subsequent Infracost run is recorded below.

## Cost and deployment status

Initial implementation validation did not include a cost estimate because no Infracost credential or measured usage profile was available. Infracost has since been configured and verified as recorded below. Actual spending remains unknown without usage inputs and pricing-model reconciliation. Main recurring drivers are per-domain RDS instances, three-AZ interface endpoints, Client VPN, EKS and nodes, managed Valkey, ALB/WAF, telemetry, storage and backups. See `cost.md` for current configuration and estimate limitations.

Deployment is an operator workflow only. CI has no AWS provisioning credentials, deployment role or apply/destroy jobs. State bootstrap, infrastructure and Kubernetes roots remain independent. No production changes or state migrations were performed.

## Infracost setup follow-up — 2026-10-17

- Checksum-pinned Infracost 0.10.46 estimated dev, staging and prod locally without unresolved Terraform-variable warnings. Reports preserve unadjusted tool totals and identify missing SNS pricing, unspecified usage and the MySQL 8.4 extended-support matching issue documented in `cost.md`.
- The [hosted Infracost workflow](https://github.com/luisiturrios1/eks-startup-platform/actions/runs/39013695545) passed using the Actions repository secret and uploaded `infracost-estimates`. Credentials, generated tfvars, state and plans are excluded from the published source and report artifact.
- Local validation passed: 20 Python tests (three Docker tests skipped), seven Terraform root validations, two mocked plans, Helm checks, TFLint, configured HIGH/CRITICAL Trivy scanning and Gitleaks. Terraform Checkov reported 538 passed, zero failed and 41 existing resource-scoped skips. No new Docker/Maven integration or live AWS acceptance tests were run for this follow-up.

## Final local rollout

`scripts/local_kind.sh && .venv/bin/python scripts/local_smoke.py` passed after rebuilding the final Java 21 image. Both migration Jobs completed before application rollout. Both services passed HTTP, database-write, Valkey and S3 checks; a cross-namespace connection was denied by Calico NetworkPolicy. The local Docker/MiniStack databases, Valkey and `kind-platform-local` cluster were left running for development. Follow `local.md` for scoped cleanup.

## AGENTS.md audit fixes — 2026-10-17

All five audit findings are addressed in code: Karpenter tagging requires creation context or prior ownership; strict system policies precede CoreDNS/controllers; application and collector leaf certificates reload; scanner exceptions identify individual resources; and unused managed cache resources are omitted. The CoreDNS cross-root transfer, cache address moves, deletion safeguards and rollback/retention procedures are documented in `deployment.md`. No AWS state transfer or deployment was executed.

| Check executed for these fixes | Result |
|---|---|
| `PATH="$PWD/.artifacts/bin:$PATH" scripts/validate.sh` | Passed: formatting, all environment contracts, policy checks, seven backend-disabled root initializations/validations, 25 Python tests (three opt-in Docker tests skipped), three mocked Terraform plans, all three local charts and pinned controller image checks. |
| `.artifacts/bin/tflint --recursive` | Passed. |
| `uv tool run --python 3.12 checkov -d . --compact -o json` | Terraform: 536 passed, zero failed, 41 scoped skips. Dockerfiles: 65 passed, zero failed, two justified runtime-health skips. Zero parsing errors. |
| Trivy root HIGH/CRITICAL scan with `--skip-dirs charts` and the existing generated/dependency exclusions | Passed; AWS exceptions use expiring annotations on the individual resources. Missing optional/operator Terraform inputs still produce static-evaluation warnings; this is not plan validation. |
| `scripts/scan_manifests.sh` | Passed: resolved platform, system-network, production service and migration manifests. CI now scans these rendered objects separately instead of parsing Go templates as raw Kubernetes YAML. |
| `.artifacts/bin/gitleaks dir . --redact --config .gitleaks.toml` | No leaks found. |
| `examples/apps/mvnw -B -f examples/apps/pom.xml test` | Two tests passed, including a real TLS handshake before/after an atomic projected-Secret symlink swap, with hostname/CA validation and no Tomcat restart. No database/emulator provisioning. |
| Scanner isolation regression exercise | A temporary HCL fixture suppressed only its annotated approved ALB and still reported the neighboring unapproved ALB. |
| `.venv/bin/python scripts/estimate_costs.py` | All three roots estimated without unresolved input warnings. Example capacity remains $1,078.28/month each for dev/staging and $1,231.81/month for prod, as unadjusted, incomplete CLI estimates. The known MySQL pricing-model issue, missing SNS price and 79 unspecified usage components per environment still require reconciliation; see `cost.md`. |

The new network tests evaluate allowed and denied flows against rendered policy objects, including DNS/API bootstrapping, webhooks, kubelet metrics, Pod Identity, telemetry and rejected Internet/metadata access. These tests do not emulate VPC CNI eBPF or prove AWS packet paths. Cache plans cover all consumers enabled, all disabled, and mixed permissions; IAM assertions cover creation-only tagging and immutable ownership keys on updates.

The configured examples still request cache, so these fixes introduce no additional billable capacity and do not claim a measured cache saving. With no consumers, a new environment has no managed Valkey nodes/users/subnet group/alarm. Existing cache retirement remains deliberately blocked until its data-retention/deletion review.

No AWS plan, apply, destroy, import, state removal/migration, regional preflight or live acceptance check was executed. Docker/MiniStack and Maven integration suites were not rerun: these changes were checked without sharing or provisioning emulator infrastructure on the active Docker daemon. Existing deployments require the explicitly authorized CoreDNS ownership transfer before the complete new roots can be applied. Review actual plans for replacements/deletions and confirm DNS, controller connectivity, TLS renewal and cache behavior in AWS before deployment approval.

Design references: [Karpenter tagging boundaries](https://karpenter.sh/v1.15/reference/cloudformation/), [AWS strict network-policy requirements](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html), [Spring Boot PEM reload](https://docs.spring.io/spring-boot/3.5/reference/features/ssl.html), [collector TLS reload](https://github.com/open-telemetry/opentelemetry-collector/blob/main/config/configtls/README.md), and [Trivy resource-scoped exceptions](https://trivy.dev/docs/latest/guide/scanner/misconfiguration/config/config/).

## Dependabot integration — 2026-10-17

Integrated the dependency changes from PRs #1–5, #7–13 and #15, preserving their original commits/authors with cherry-pick provenance. At that time, PRs #6 and #14 were excluded because their Java 24/26 images violated the then-current Java 21 platform contract. The corresponding Dependabot ignores and Java 21 regression check were replaced by the coordinated Java 26 migration on 2026-10-18.

Spring Boot 4.1.1 required the modular MVC/OpenTelemetry starters, Jackson 3 imports, new auto-configuration packages, Testcontainers 2 modules and tracing-export configuration. That release retained Java 21 and Flyway 11.20.3. Maven Wrapper 3.10.0 has a verified distribution checksum and is used by Docker builds. The credential-manager runtime dependencies matched the updated Python test environment, including boto3 1.43.113 and psycopg 3.3.6 at that time. Policy parsing explicitly selects python-hcl2 8's compatible unquoted serialization.

CI now uses registry-verified Linux AMD64 and macOS ARM64 provider hashes, a checksum-verified asset cache with bounded download retries, and secret-free Dependabot cost-input validation. Trusted main/manual runs still perform pricing. No privileged pull-request trigger or AWS provisioning credential was added. The local emulator setup waits for actual SQL readiness before provisioning users.

| Check executed for the integrated dependencies | Result |
|---|---|
| `PATH="$PWD/.artifacts/bin:$PATH" scripts/validate.sh` | Passed: seven backend-disabled root initializations/validations, all environment contracts, policy checks, 30 Python tests (three opt-in integration tests skipped here), three mocked Terraform plans, chart lint/render and private image checks. |
| `.artifacts/bin/tflint --recursive` | Passed. |
| `uv tool run --python 3.12 checkov -d . --compact -o json` | Terraform: 536 passed, zero failed, 41 documented scoped skips. Dockerfiles were scanned again after the final Wrapper build fix: 82 passed, zero failed, two justified skips. Zero parsing errors. |
| Configured Trivy HIGH/CRITICAL root scan and `scripts/scan_manifests.sh` | Passed with the existing documented, scoped exceptions. |
| `.artifacts/bin/gitleaks dir . --redact --config .gitleaks.toml` and `git diff --check` | Passed; no leaks found. |
| `examples/apps/mvnw -B -f examples/apps/pom.xml verify` | Passed on Java 21 in an isolated Docker daemon: two unit/TLS tests and one real MiniStack/PostgreSQL 17.6/MySQL 8.4.6 integration test, including expected migration failure and secret refresh. |
| `PLATFORM_LOCAL_INTEGRATION=1 .venv/bin/pytest -q tests/integration` | Three passed on the same isolated daemon after Maven completed: SQL grant isolation, credential rotation and Valkey isolation. |
| `scripts/local_kind.sh && .venv/bin/python scripts/local_smoke.py` | Passed after the Python suite on the isolated daemon: Java 21 image built with the checksum-verified Wrapper, both migration Jobs completed before rollout, both services passed HTTP/database/Valkey/S3 checks, and Calico denied a cross-namespace connection. |
| `scripts/prepare-assets.sh` | Passed with verified cached files; regression tests cover reuse, invalid cache rejection, transient retries and invalid download rejection. |
| `scripts/estimate_costs.py --validate-only` and full `scripts/estimate_costs.py` | Both passed. Partial example estimates remain $1,078.28/month each for dev/staging and $1,231.81/month for prod. The documented missing usage/prices and MySQL support-model issue remain; these are incomplete estimates. |

These updates add no AWS capacity and introduce no deployment step. No AWS plan, apply, destroy, state access or migration was performed. The CoreDNS transfer and other AWS acceptance requirements above still apply to existing deployments. Local emulator suites run serially and cannot establish AWS networking, IAM, WAF or managed-service guarantees.

### PyMySQL follow-up during integration

Dependabot opened PRs #16 and #17 after the component directory was added to its coverage. Both changes were also integrated with cherry-pick provenance: test and runtime requirements now use PyMySQL 1.2.3. Its [upstream changes](https://github.com/PyMySQL/PyMySQL/blob/v1.2.3/CHANGELOG.md) include SQL-escaping fixes and revised TLS negotiation; the production connector still explicitly requires certificate and hostname verification.

After this update, the local Python suite passed 33 tests with three opt-in tests skipped. Three added loopback protocol tests exercise the actual production connector and reject a server without TLS, an untrusted CA with a matching hostname, and a trusted certificate with the wrong hostname before authentication. The three real SQL/Valkey permission and rotation tests passed again on a fresh isolated Docker daemon. Gitleaks and `git diff --check` passed. Both dedicated test daemons and their volumes were then removed; the user's original development containers were preserved.

## Consolidated dependencies and Java 26 — 2026-10-18

PRs #14 and #18–21 are incorporated with cherry-pick provenance. PR #6 is superseded by a Java 26 runtime instead of Java 24. Maven target, CI JDK, build/runtime images, the image lock, policy test and current documentation now agree on Java 26. The Wrapper remains checksum-verified Maven 3.10.0. The runtime manifest digest was verified against Docker Hub; the Maven digest and checkout 7.0.1 commit were independently verified against their upstream registries. See [migration, support risk and rollback](java26.md).

| Check executed for this consolidation | Result |
|---|---|
| `PATH="$PWD/.artifacts/bin:$PATH" scripts/validate.sh` | Passed: formatting, contracts for dev/staging/prod, repository policy, seven backend-disabled root initializations/validations, 33 Python tests (three opt-in integration tests skipped), three mocked Terraform plans, Helm lint/render and private-image checks. |
| `JAVA_HOME=.../jdk-26.0.2.1+1/Contents/Home examples/apps/mvnw -B -f examples/apps/pom.xml clean test` | Two unit/TLS tests passed on checksum-verified Temurin 26.0.2.1. Compiled application bytecode reports major version 70 (Java 26). |
| `examples/apps/mvnw -B -f examples/apps/pom.xml clean verify` on the isolated daemon | Passed on Temurin 26.0.2.1: two unit/TLS tests plus the real MiniStack/PostgreSQL 17.6/MySQL 8.4.6 integration test. Both services, concurrent Flyway migrations, expected migration failure, secret refresh and S3 operations passed. |
| `docker build --tag platform-examples:local examples/apps` on the isolated daemon | Passed with both pinned Java 26 bases and the checksum-verified Wrapper. RDS CA import completed; the resulting image reports Java 26.0.2.1 and runs as user `10001:10001`. This local build targets Linux ARM64; hosted CI exercises Linux AMD64. |
| `docker compose up -d --wait`, `scripts/local_setup.py`, then `PLATFORM_LOCAL_INTEGRATION=1 .venv/bin/pytest -q tests/integration` on the isolated daemon | Three tests passed serially after Maven: SQL privileges and cross-service denial, overlapping credential rotation and Valkey key isolation, with boto3 1.43.114. |
| `scripts/local_kind.sh && .venv/bin/python scripts/local_smoke.py` on the isolated daemon | Passed after the Python suite: both migration Jobs completed before rollout, both Java 26 services passed HTTP/database-write/Valkey/S3 checks, and Calico denied a cross-namespace connection. |
| `.venv/bin/python -m pytest -q tests` after updating boto3 | 33 passed, three opt-in integration tests skipped. |
| `.artifacts/bin/tflint --recursive` | Passed. |
| `uv tool run --python 3.12 checkov -d . --compact -o json` | Terraform: 536 passed, zero failed, 41 existing scoped skips. Dockerfiles: 82 passed, zero failed, two existing scoped health-check skips. Zero parsing errors. |
| Configured Trivy HIGH/CRITICAL configuration scan and `scripts/scan_manifests.sh` | Passed with existing documented exceptions; this is not a base-image vulnerability scan. |
| `.artifacts/bin/gitleaks dir . --redact --config .gitleaks.toml` and `git diff --check` | Passed; no leaks found. |
| `scripts/prepare-assets.sh` and `scripts/estimate_costs.py --validate-only` | Passed. |
| `.venv/bin/python scripts/estimate_costs.py` | Passed for all three environments. Partial, unadjusted example estimates remain $1,078.28/month each for dev/staging and $1,231.81/month for prod. There are still 79 unspecified usage components, one missing price and the known MySQL model limitation per environment; see `cost.md`. |

All real-infrastructure emulator suites ran serially on the dedicated daemon. That test daemon and its anonymous volumes were removed after validation; the original developer containers were preserved. Logs remain under ignored `.artifacts/java26-*.log`. These local checks do not establish AWS networking, IAM, WAF, managed failover or production acceptance. Hosted Linux AMD64 CI and Infracost results are recorded separately in the consolidated PR's checks.

Temurin 26 is EOSL; this remains a production runtime support risk even with passing tests/scans. No new suppression or production security waiver was added. No Terraform resources, IAM permissions, endpoints, state, schema SQL or AWS capacity changed. JVM CPU/memory, image transfer and CI cost changes are unmeasured. No AWS plan, deployment, apply, destroy, state operation or ECR promotion was performed. Production promotion still requires a maintained runtime strategy, environment authorization and reviewed plans.
