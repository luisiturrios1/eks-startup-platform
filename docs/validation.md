# Implementation validation — 2026-10-17

This records local evidence, not AWS deployment acceptance. The repository implements the AWS infrastructure, Kubernetes configuration, service contract, credential lifecycle, Java examples and validation-only CI described in README.

## Executed checks

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

Local Maven used host Java 25 with Java 21 compilation target; the container build uses Java 21, and CI explicitly installs Java 21. Helm CLI checks used Helm 4 locally; CI pins Helm 3.19.0 and the Terraform provider uses Helm 3. Private-image rendering checks account for the CLI post-render interface difference.

## Remaining acceptance and operational review

- No AWS plan, apply, destroy, state import, migration or live acceptance test was executed. Expected initial plans create the platform; inspect actual plans before authorization, especially IAM, public ingress, replacements and stateful resources.
- Supply real account IDs, stable AZ IDs, regional engine/add-on availability, SAML identity provider and MFA configuration, VPN certificates, DNS, ACM certificate, private ECR image digests and AMI selection. Example image references intentionally cannot deploy.
- Run the read-only regional preflight with authorized credentials. The current ARN and endpoint conventions target commercial AWS partitions; GovCloud and China are not validated.
- Verify VPN-only administrative access, endpoint packet paths and policies, AWS Pod Identity, managed RDS privileges/TLS and rotation, Valkey IAM authentication, CloudWatch/X-Ray delivery, WAF enforcement, failover and restore in AWS. MiniStack cannot establish these guarantees.
- Review resource-scoped scanner exceptions before deployment; their review deadline is 2027-01-16. Demo HTTP APIs illustrate integration and do not implement production payment processing or identity authentication.
- Database engine/group/placement changes require an explicit data migration and rollback plan. No automatic destructive migration is included.
- The GitHub Actions workflow was inspected and its underlying checks run locally; a hosted Actions run has not been observed.

## Cost and deployment status

Monthly cost remains **unknown**: no Infracost credential or measured usage profile was provided, so cost estimation was not executed. Main recurring drivers are per-domain RDS instances, three-AZ interface endpoints, Client VPN, EKS and nodes, managed Valkey, ALB/WAF, telemetry, storage and backups. See `cost.md` for required estimation inputs and production resilience costs.

Deployment is an operator workflow only. CI has no AWS provisioning credentials, deployment role or apply/destroy jobs. State bootstrap, infrastructure and Kubernetes roots remain independent. No production changes or state migrations were performed.

## Final local rollout

`scripts/local_kind.sh && .venv/bin/python scripts/local_smoke.py` passed after rebuilding the final Java 21 image. Both migration Jobs completed before application rollout. Both services passed HTTP, database-write, Valkey and S3 checks; a cross-namespace connection was denied by Calico NetworkPolicy. The local Docker/MiniStack databases, Valkey and `kind-platform-local` cluster were left running for development. Follow `local.md` for scoped cleanup.
