package com.example.platform;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import jakarta.annotation.PreDestroy;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.jdbc.datasource.AbstractDataSource;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;

@Component
public class RotatingDataSource extends AbstractDataSource implements AutoCloseable {
    private final SecretsManagerClient secrets;
    private final Environment env;
    private final ScheduledExecutorService retirement = Executors.newSingleThreadScheduledExecutor();
    private volatile HikariDataSource pool;
    private String version;
    public RotatingDataSource(SecretsManagerClient secrets, Environment env) throws Exception {
        this.secrets=secrets; this.env=env; refresh();
    }
    @Scheduled(fixedDelay=60000)
    public synchronized void refresh() throws Exception {
        var value = secrets.getSecretValue(b -> b.secretId(env.getRequiredProperty("DB_SECRET_ID")));
        if (pool != null && value.versionId().equals(version)) return;
        var json = new ObjectMapper().readTree(value.secretString());
        String engine = json.get("engine").asText();
        if (!engine.equals("postgres") && !engine.equals("mysql")) throw new IllegalArgumentException("Unsupported database engine");
        boolean local = env.acceptsProfiles(Profiles.of("local"));
        String protocol = engine.equals("postgres") ? "postgresql" : "mysql";
        String options = engine.equals("postgres")
            ? (local ? "sslmode=disable" : "sslmode=verify-full&sslrootcert=/etc/rds/global-bundle.pem")
            : (local ? "sslMode=REQUIRED&allowPublicKeyRetrieval=true" : "sslMode=VERIFY_IDENTITY");
        var config = new HikariConfig();
        config.setJdbcUrl("jdbc:"+protocol+"://"+(local ? env.getProperty("DB_HOST_OVERRIDE",json.get("host").asText()) : json.get("host").asText())+":"+(local ? env.getProperty("DB_PORT_OVERRIDE",json.get("port").asText()) : json.get("port").asText())+"/"+json.get("dbname").asText()+"?"+options);
        config.setUsername(json.get("username").asText());config.setPassword(json.get("password").asText());
        config.setMaximumPoolSize(5);config.setMinimumIdle(1);config.setConnectionTimeout(10000);
        config.setPoolName("service-"+System.nanoTime());
        HikariDataSource replacement = new HikariDataSource(config);
        try (var connection = replacement.getConnection()) { if (!connection.isValid(5)) throw new SQLException("Database validation failed"); }
        catch (Exception failure) { replacement.close();throw failure; }
        HikariDataSource previous = pool;pool = replacement;version = value.versionId();
        if (previous != null) retirement.schedule(previous::close,60,TimeUnit.SECONDS);
    }
    @Override public Connection getConnection() throws SQLException { return pool.getConnection(); }
    @Override public Connection getConnection(String u,String p) throws SQLException { throw new SQLException("Use service identity"); }
    @PreDestroy public void close() { retirement.shutdown();if(pool!=null)pool.close(); }
}
