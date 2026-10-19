#checkov:skip=CKV_DOCKER_2:Kubernetes startup, readiness and liveness probes in charts/service own runtime health; a Docker HEALTHCHECK would not run in Kubernetes. See docs/security-exceptions.md.
FROM maven:3.9-eclipse-temurin-26@sha256:b2c1ad85954592f9928e84327c65201f308ad9b5d8ed7d5b823717c97bf23fbb AS build
# Keep the wrapper on the ZIP artifact covered by distributionSha256Sum.
RUN apt-get update && apt-get install -y --no-install-recommends unzip=6.0-28ubuntu4.1 && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY pom.xml mvnw ./
COPY .mvn ./.mvn
COPY src ./src
RUN ./mvnw -B -DskipTests package
FROM eclipse-temurin:26-jre@sha256:c7c9e2d412999f6a99d3cd987ed95ce55d9d52e2dcaf8577a9b495077d825c78
WORKDIR /app
COPY --from=build /build/target/platform-examples-1.0.0.jar /app/app.jar
COPY global-bundle.pem /etc/rds/global-bundle.pem
COPY import-ca.sh /tmp/import-ca.sh
RUN sh /tmp/import-ca.sh && rm /tmp/import-ca.sh
USER 10001:10001
EXPOSE 8443
ENTRYPOINT ["java","-jar","/app/app.jar"]
