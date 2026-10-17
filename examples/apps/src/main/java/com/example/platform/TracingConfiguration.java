package com.example.platform;

import java.nio.file.Files;
import java.nio.file.Path;
import io.opentelemetry.exporter.otlp.http.trace.OtlpHttpSpanExporter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.core.env.Environment;

@Configuration
@Profile("!local & !migration")
class TracingConfiguration {
    @Bean OtlpHttpSpanExporter spanExporter(Environment env) throws Exception {
        return OtlpHttpSpanExporter.builder()
            .setEndpoint(env.getProperty("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT","https://telemetry.amazon-cloudwatch.svc:4318/v1/traces"))
            .setTrustedCertificates(Files.readAllBytes(Path.of("/etc/service-tls/ca.crt"))).build();
    }
}
