package com.example.platform;

import java.net.URI;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.s3.S3Client;

@Configuration
class AwsConfiguration {
    static URI localEndpoint(Environment env) {
        String endpoint = env.getProperty("AWS_ENDPOINT_URL");
        if (endpoint != null && !env.acceptsProfiles(Profiles.of("local")))
            throw new IllegalStateException("AWS endpoint overrides are only allowed in the local profile");
        return endpoint == null ? null : URI.create(endpoint);
    }
    @Bean SecretsManagerClient secrets(Environment env) {
        var builder = SecretsManagerClient.builder().region(Region.of(env.getProperty("AWS_REGION", "us-east-1")))
            .credentialsProvider(DefaultCredentialsProvider.create());
        URI endpoint = localEndpoint(env);
        if (endpoint != null) builder.endpointOverride(endpoint);
        return builder.build();
    }
    @Bean S3Client s3(Environment env) {
        var builder = S3Client.builder().region(Region.of(env.getProperty("AWS_REGION", "us-east-1")))
            .credentialsProvider(DefaultCredentialsProvider.create());
        URI endpoint = localEndpoint(env);
        if (endpoint != null) builder.endpointOverride(endpoint).forcePathStyle(true);
        return builder.build();
    }
}
