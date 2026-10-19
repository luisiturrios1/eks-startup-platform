# Reviewed scanner exceptions and permission boundaries

Review by **2027-01-16**, or immediately when the associated control changes. Inline Checkov notes apply only to the named resource/image. AWS Trivy exceptions are inline annotations on the public ALB and audit-bucket encryption configuration, with expiry. The remaining Trivy path exception names a file containing only the Fluent Bit DaemonSet; a regression test rejects additional YAML resources in that file. All exceptions retain the same review deadline. These are design rationales, not a claim of an organizational approval. A deployment reviewer must accept the applicable residual risks.

| Finding | Scope and reason | Compensating control |
|---|---|---|
| Public ALB (Trivy AWS-0053) | Public HTTPS APIs explicitly requested | WAF, TLS 1.2/1.3, HTTPS targets, private application subnets, ALB-only backend security-group ingress |
| Lambda code signing CKV_AWS_272 | AWS does not support Lambda code-signing configurations for container images | Immutable ECR digests, scanning and reviewed artifact provenance; verify signatures before promotion |
| IAM ENI permissions CKV_AWS_290/355 | Credential Lambda needs ENI lifecycle/discovery operations for VPC attachment | Dedicated role; database/secret/KMS permissions are scoped; runtime/migration roles do not inherit Lambda permissions |
| Secret rotation CKV2_AWS_57 | Uses a custom scheduled alternating-user workflow rather than Secrets Manager's native rotation hook | 30-day schedule, reserved concurrency, retryable pending versions, tested grants, DLQ and error alarms |
| RDS transport CKV2_AWS_69 | Static graph cannot resolve both engine-selected parameter groups | PostgreSQL `rds.force_ssl=1`, MySQL `require_secure_transport=1`; production clients verify CA and hostname |
| WAF association CKV2_AWS_76 | Graph resolution misses the managed rule in the associated WebACL | Explicit KnownBadInputs and CommonRuleSet, plus rate rule; review plan and live WAF behavior |
| SG attachment CKV2_AWS_5 | SG IDs cross the networking module output boundary | EKS/Lambda, ALB, RDS and ElastiCache explicitly consume them; mocked plan and AWS acceptance verify attachment |
| One-year application/request retention CKV_AWS_338 | Application/WAF logs use 30 days; no compliance mandate for one year was supplied | Security audit, EKS and network logs retain 365 days; WAF logs redact credentials/query strings |
| S3 notifications CKV2_AWS_62 | No object event consumer is required | State CloudTrail data events and S3 access logs provide audit; no unused notification infrastructure |
| S3 replication CKV_AWS_144 | Approved baseline is single-region with Multi-AZ availability | Versioning, backups and restore runbook; regional outage RPO/RTO is not promised |
| S3 SSE-S3 CKV_AWS_145 / Trivy AWS-0132 | ALB/S3 access-log destinations require compatible server-side encryption | Private, versioned SSE-S3 buckets; CloudTrail objects are additionally KMS-encrypted; application/state buckets use KMS |
| CloudTrail SNS CKV_AWS_252 | File-delivery SNS notifications are not required | Encrypted CloudWatch Logs integration and validated CloudTrail log files |
| Docker HEALTHCHECK CKV_DOCKER_2 | Only `examples/apps/Dockerfile` and `components/credential-manager/Dockerfile`: Kubernetes probes and Lambda runtime supervision own health checks; Docker image health checks do not run in those runtimes | Application startup/readiness/liveness probes, Lambda errors and DLQ alarms remain enabled |
| Fluent Bit root / host logs | Root is required to read root-owned host container logs | Read-only host mount/root filesystem, dropped capabilities, no privilege escalation, runtime-default seccomp; application pods remain restricted/non-root |

AWS API Describe operations and telemetry publishing sometimes require `Resource="*"`. These appear only in controller roles. Karpenter ownership tags can only be added during EC2 creation (`ec2:CreateAction`). Subsequent tag updates require existing cluster/nodepool ownership, permit only Name/nodeclaim/cluster-name keys, and cannot rewrite the tags that authorize deletion. Instance deletion still requires existing ownership; PassRole names the node role and EC2 service. The load balancer controller only discovers resources and registers/deregisters targets in Terraform-created target groups; it cannot create public load balancers or change WAF.

Endpoint policies restrict interface access to the account, while workload IAM restricts actions/resources. S3 permits the regional ECR layer bucket in addition to account-owned objects. KMS account-root statements enable IAM delegation; application grants remain scoped. Review endpoint-specific policy support during the regional preflight/plan.

Sources: [Lambda container signing limitation](https://docs.aws.amazon.com/lambda/latest/dg/configuration-codesigning-create.html), [MiniStack limitations](https://ministack.org/docs/limitations). Scanner exceptions are not evidence that AWS runtime behavior has been tested.

## Java 26 runtime support risk — 2026-10-18

The user requested Java 26 for the application examples. This affects only the `maven` and `java` base-image entries in `config/images.lock.json`, `examples/apps/Dockerfile`, the Maven target and the application CI JDK. [Adoptium marks Temurin 26 as EOSL after September 2026](https://adoptium.net/support/); digest pinning and a clean scan do not provide future security fixes. No scanner suppression is added and this note is not a production waiver. Before production promotion, require a confirmed maintained runtime strategy and explicit security review as described in [the migration guide](java26.md); review this risk before every promotion and no later than 2027-01-16.
