package com.example.platform;

import java.sql.DriverManager;
import java.util.Map;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;
import org.testcontainers.postgresql.PostgreSQLContainer;
import org.testcontainers.mysql.MySQLContainer;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.utility.DockerImageName;
import software.amazon.awssdk.auth.credentials.AwsBasicCredentials;
import software.amazon.awssdk.auth.credentials.StaticCredentialsProvider;
import software.amazon.awssdk.regions.Region;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;
import software.amazon.awssdk.services.s3.S3Client;
import tools.jackson.databind.ObjectMapper;
import static org.junit.jupiter.api.Assertions.*;

class DatabaseIT {
    @Test void bothServicesBothEnginesAndSecretRefresh() throws Exception {
        try (var mini=new ScopedMiniStackContainer();
             var postgres=new PostgreSQLContainer("postgres:17.6");
             var mysql=new MySQLContainer("mysql:8.4.6")) {
            mini.start();postgres.start();mysql.start();
            var endpoint=java.net.URI.create("http://"+mini.getHost()+":"+mini.getMappedPort(4566));
            var credentials=StaticCredentialsProvider.create(AwsBasicCredentials.create("test","test"));
            try (var sm=SecretsManagerClient.builder().endpointOverride(endpoint).region(Region.US_EAST_1).credentialsProvider(credentials).build();
                 var s3=S3Client.builder().endpointOverride(endpoint).region(Region.US_EAST_1).credentialsProvider(credentials).forcePathStyle(true).build()) {
                for (var engine : new String[]{"postgres","mysql"}) {
                    var db=engine.equals("postgres") ? postgres : mysql;
                    Runnable migrate=()->Flyway.configure().dataSource(db.getJdbcUrl(),db.getUsername(),db.getPassword())
                        .locations("classpath:db/migration/"+engine).load().migrate();
                    java.util.concurrent.CompletableFuture.allOf(
                        java.util.concurrent.CompletableFuture.runAsync(migrate),
                        java.util.concurrent.CompletableFuture.runAsync(migrate)).join();
                    for (var service:new String[]{"payments-service","auth-service"}) {
                        String id=service+"-"+engine;
                        String value=new ObjectMapper().writeValueAsString(Map.of("engine",engine,"host",db.getHost(),"port",db.getFirstMappedPort(),"dbname",db.getDatabaseName(),"username",db.getUsername(),"password",db.getPassword()));
                        sm.createSecret(b->b.name(id).secretString(value));
                        var env=new MockEnvironment().withProperty("DB_SECRET_ID",id);env.setActiveProfiles("local");
                        try(var source=new RotatingDataSource(sm,env)) {
                            try(var connection=source.getConnection();var statement=connection.prepareStatement("INSERT INTO demo_records(id,service_name) VALUES (?,?)")) {
                                statement.setString(1,java.util.UUID.randomUUID().toString());statement.setString(2,service);assertEquals(1,statement.executeUpdate());
                            }
                            sm.putSecretValue(b->b.secretId(id).secretString(value));
                            source.refresh();try(var connection=source.getConnection()){assertTrue(connection.isValid(5));}
                        }
                        s3.createBucket(b->b.bucket(id));s3.putObject(b->b.bucket(id).key("test"),software.amazon.awssdk.core.sync.RequestBody.fromString("ok"));
                        assertEquals("ok",s3.getObjectAsBytes(b->b.bucket(id).key("test")).asUtf8String());
                    }
                    assertThrows(org.flywaydb.core.api.FlywayException.class,()->Flyway.configure()
                        .dataSource(db.getJdbcUrl(),db.getUsername(),db.getPassword())
                        .locations("classpath:db/migration/"+engine,"classpath:db/invalid").load().migrate());
                    try(var connection=DriverManager.getConnection(db.getJdbcUrl(),db.getUsername(),db.getPassword());var query=connection.createStatement();var rows=query.executeQuery("SELECT COUNT(*) FROM demo_records")) {
                        assertTrue(rows.next());assertEquals(2,rows.getInt(1));
                    }
                }
            }
        }
    }
}
