#checkov:skip=CKV_DOCKER_2:Kubernetes startup, readiness and liveness probes in charts/service own runtime health; a Docker HEALTHCHECK would not run in Kubernetes. See docs/security-exceptions.md.
FROM maven:3.9.11-eclipse-temurin-21@sha256:6fdc855a6ed81d288ca7ca37ac6ff5e9308b612485c0801d70b25a858c83d237 AS build
WORKDIR /build
COPY pom.xml .
COPY src ./src
RUN mvn -B -DskipTests package
FROM eclipse-temurin:21-jre@sha256:ccbad9e7cb84c27092b12c40a4143e5733e050db9c3784d84f632dcf423fb2ef
WORKDIR /app
COPY --from=build /build/target/platform-examples-1.0.0.jar /app/app.jar
COPY global-bundle.pem /etc/rds/global-bundle.pem
COPY import-ca.sh /tmp/import-ca.sh
RUN sh /tmp/import-ca.sh && rm /tmp/import-ca.sh
USER 10001:10001
EXPOSE 8443
ENTRYPOINT ["java","-jar","/app/app.jar"]
