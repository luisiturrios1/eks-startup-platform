# Java 26 migration and dependency consolidation

The examples now compile and run on Java 26. This replaces the earlier Java 21 contract at the user's request; the validation evidence dated 2026-10-17 in `validation.md` describes the previous release, not Java 26 acceptance.

## Versions and provenance

| Component | Consolidated version |
|---|---|
| Maven compilation target and CI Temurin JDK | Java 26 |
| Build base | `maven:3.9-eclipse-temurin-26`, pinned by digest |
| Runtime base | `eclipse-temurin:26-jre`, pinned by digest |
| Maven distribution actually invoked, including Docker | Checksum-verified Wrapper 3.10.0 |
| Spring Boot / Flyway | 4.1.1 / 11.20.3 |
| AWS SDK BOM | 2.56.0 |
| Python boto3, development and credential manager | 1.43.114 |
| actions/checkout | 7.0.1, pinned to `3d3c42e5aac5ba805825da76410c181273ba90b1` |

The build image supplies the JDK; its bundled Maven is not used. `Dockerfile` and `config/images.lock.json` record the same multi-architecture manifest digests, verified against Docker Hub. The Java policy test checks the build/runtime majors, those lock entries, the POM target and CI together. Dependabot can propose new images; a different Java major still requires a coordinated contract change.

PRs #18–21 and #14 are incorporated with their original Dependabot commits and cherry-pick provenance. PR #6's Java 24 runtime proposal is superseded by Java 26 to match compilation; it is not applied verbatim.

## Support and security review

[Spring Boot 4.1.1 supports Java through 26](https://docs.spring.io/spring-boot/4.1/system-requirements.html). However, [Adoptium lists Temurin 26 as end of service/support life](https://adoptium.net/support/), with availability ending in September 2026 and no further builds planned. Java 26 is not LTS. Pinning a digest ensures reproducibility, not ongoing security updates.

This migration does not establish production security acceptance. Before production promotion, choose and validate a maintained Java distribution with confirmed Java 26 coverage, or separately approve a migration to a supported Java release. A clean vulnerability scan cannot resolve the absence of future runtime fixes. Record the decision and reviewer; no support contract or security waiver is implied by this repository change. See also `security-exceptions.md`.

Checkout 7 runs on Node 24 and requires an Actions runner at least 2.327.1; the configured GitHub-hosted `ubuntu-latest` runners satisfy the documented runner requirement. See [upstream requirements](https://github.com/actions/checkout/tree/v7.0.1). Workflows remain validation-only with read-only repository permissions and no privileged pull-request trigger or AWS provisioning credentials.

## Validation and rollout

1. Select JDK 26 in `JAVA_HOME`; verify `java -version`, `javac -version` and `examples/apps/mvnw -version`. Run `examples/apps/mvnw -B -f examples/apps/pom.xml clean verify`. Java 21/25 cannot compile this target. No preview features are enabled.
2. Run `scripts/validate.sh` and configured security scans. Run Maven integration, Python integration and kind smoke suites serially on an isolated Docker daemon. Preserve existing developer containers. See `local.md` and the current evidence in `validation.md`.
3. Build and scan the complete application image for `linux/amd64` before an operator promotes its immutable digest to private ECR. Confirm both services, migration Jobs, database TLS, certificate reload, credential refresh, cache and S3 behavior. Public base images are build inputs; application subnets retain private ECR runtime dependencies.
4. Review each environment's service image digest and deployment plan. Retain the previous image and configuration. Follow `deployment.md` for approved migration-before-rollout behavior. No deployment, state transfer, schema change or new AWS resource is part of this dependency update.

## Rollback and cost

Java 26 bytecode cannot execute on Java 21. Roll back to the complete previous application image and its matching release configuration, or revert the build/runtime/POM/CI contract together and rebuild. Do not merely replace the JRE under the new JAR. No Flyway SQL files change here; a later release with schema changes needs its own compatibility and recovery plan. Existing database ownership and migration credentials are unchanged.

No AWS capacity, retention, traffic route, IAM policy or billable resource is added. CPU, memory, startup time, image transfer and CI duration can change with the JDK; their cost impact is unknown until representative workloads are measured. Existing Infracost estimates describe configured AWS capacity and do not measure Java performance or GitHub runner usage.
