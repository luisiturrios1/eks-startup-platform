package com.example.platform;

import java.util.Map;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@Profile("!migration")
class Api {
    private final JdbcTemplate jdbc;
    private final String service;
    private final CacheClient cache;
    private final software.amazon.awssdk.services.s3.S3Client s3;
    private final Environment env;
    Api(JdbcTemplate jdbc,Environment env,CacheClient cache,software.amazon.awssdk.services.s3.S3Client s3) { this.jdbc=jdbc;this.env=env;this.cache=cache;this.s3=s3;this.service=env.getProperty("SERVICE_NAME","payments-service"); }
    @PostMapping("/api/cache") Map<String,String> cache() { return Map.of("value",cache.putAndRead("demo")); }
    @PostMapping("/api/object") Map<String,String> object() {
        String key=java.util.UUID.randomUUID().toString();
        s3.putObject(b->b.bucket(env.getRequiredProperty("S3_BUCKET")).key(key),software.amazon.awssdk.core.sync.RequestBody.fromString("demo"));
        return Map.of("key",key);
    }
    @GetMapping("/api/info") Map<String,Object> info() {
        return Map.of("service",service,"example",true,"records",jdbc.queryForObject("SELECT COUNT(*) FROM demo_records",Long.class));
    }
    @PostMapping("/api/demo") Map<String,String> create() {
        String id=UUID.randomUUID().toString();jdbc.update("INSERT INTO demo_records(id,service_name) VALUES (?,?)",id,service);
        return Map.of("id",id,"service",service);
    }
}
