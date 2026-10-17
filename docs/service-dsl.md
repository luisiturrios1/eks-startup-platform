# Service contract

`services/*.yaml` uses `platform/v1`. JSON-formatted YAML is accepted. Unknown fields and arbitrary IAM statements are rejected. Edit the source contracts, then run:

```bash
.venv/bin/python scripts/compile_services.py --environment dev
```

This produces ignored, non-secret `environments/dev/services.auto.tfvars.json`. Do not hand-edit it. Recompile independently for every environment. Images must be digests; AWS deployment additionally requires private ECR repositories. Service HTTPS port is fixed at 8443 by deployment policy.

## Shared RDS by domain

Environment group configuration belongs in `config/dev.json` (and staging/prod):

```json
{"database_groups":{"payments":{"domain":"payments","engine":"postgres","engine_version":"17","instance_class":"db.t4g.medium","storage_gb":20,"multi_az":false}}}
```

A service references this group:

```yaml
domain: payments
database:
  placement: shared
  group: payments
  name: payments_service
```

All consumers of a group inherit its engine/version/capacity. There is no service-level engine override for a shared group. Each service's database name must be unique within the instance. Different domains cannot reference the same group. Only used groups create instances.

For a dedicated database:

```yaml
database:
  placement: dedicated
  name: reporting_service
  engine: mysql
  engine_version: "8.4"
  instance_class: db.t4g.medium
  storage_gb: 20
```

Runtime users get DML only. Migration users have DDL on their own database. PostgreSQL revokes PUBLIC database/schema privileges and uses a stable NOLOGIN owner role so alternating migration users can manage existing objects. MySQL grants remain scoped to `database.*` without global administrative privileges or GRANT OPTION. Master credentials are accessible only to the credential manager.

Group/engine/placement changes are data migrations: provision a new target, back up, copy/replicate, validate, perform a reviewed cutover, retain rollback data, then separately approve retirement. Never edit these fields to imply an automatic move. `prevent_destroy`, final snapshots and deletion protection intentionally obstruct accidental deletion.

## Permissions and scaling

`permissions.s3` permits `read` and/or `write` on a service-specific bucket; `permissions.cache` enables a managed cache identity. Secret access is generated from ownership. `dependencies` lists allowed internal callers' destinations; reverse ingress rules are generated when exporting Helm values.

`scaling` contains `minReplicas`, `maxReplicas`, and CPU utilization. Production requires at least two replicas. Container requests drive HPA and Karpenter. Migration commands execute in a separate Job; runtime pods never receive migration credentials. Resource quotas and node capacity limits bound scaling; review these together before increasing replica limits.

Optional `secretReferences` is a list of exact existing Secrets Manager ARNs under `<project>-<environment>/<service>/`. Wildcards and cross-service/account/environment references fail validation. Terraform never fetches their values. The chart passes references through `EXTRA_SECRET_REFS`; application code can use the AWS SDK to fetch them. Populate and rotate these service-owned opaque secrets outside Terraform. Database secrets continue to use the automated credential workflow.

Additional secret references must use the platform KMS key: runtime identities have decryption permission only for that key. References containing `/database/` are reserved and rejected, preventing this extension from granting runtime access to migration credentials. Resource requests cannot exceed limits.
