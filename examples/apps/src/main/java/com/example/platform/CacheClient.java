package com.example.platform;

import java.time.Instant;
import io.lettuce.core.RedisClient;
import io.lettuce.core.RedisURI;
import org.springframework.core.env.Environment;
import org.springframework.core.env.Profiles;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;
import software.amazon.awssdk.auth.signer.Aws4Signer;
import software.amazon.awssdk.auth.signer.params.Aws4PresignerParams;
import software.amazon.awssdk.http.SdkHttpFullRequest;
import software.amazon.awssdk.http.SdkHttpMethod;
import software.amazon.awssdk.regions.Region;

@Component
class CacheClient {
    private final Environment env;
    CacheClient(Environment env) {this.env=env;}
    String putAndRead(String value) {
        String user=env.getRequiredProperty("CACHE_USER");
        boolean local=env.acceptsProfiles(Profiles.of("local"));
        String password;
        if(local) password=env.getRequiredProperty("CACHE_PASSWORD");
        else {
            var request=SdkHttpFullRequest.builder().method(SdkHttpMethod.GET).protocol("http")
                .host(env.getRequiredProperty("CACHE_RESOURCE")).encodedPath("/")
                .appendRawQueryParameter("Action","connect").appendRawQueryParameter("User",user).build();
            var signed=Aws4Signer.create().presign(request,Aws4PresignerParams.builder()
                .awsCredentials(DefaultCredentialsProvider.create().resolveCredentials())
                .signingName("elasticache").signingRegion(Region.of(env.getRequiredProperty("AWS_REGION")))
                .expirationTime(Instant.now().plusSeconds(900)).build());
            password=signed.getUri().toString().replaceFirst("^http://", "");
        }
        var uri=RedisURI.Builder.redis(env.getRequiredProperty("CACHE_HOST"),env.getProperty("CACHE_PORT",Integer.class,6379))
            .withAuthentication(user,password).withSsl(!local).build();
        var client=RedisClient.create(uri);
        try(var connection=client.connect()) {
            String key=env.getRequiredProperty("SERVICE_NAME")+":demo";
            connection.sync().setex(key,60,value);return connection.sync().get(key);
        } finally {client.shutdown();}
    }
}
