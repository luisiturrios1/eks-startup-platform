package com.example.platform;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;
import static org.junit.jupiter.api.Assertions.*;
class EndpointTest {
    @Test void endpointsCannotEscapeProduction() {
        var env=new MockEnvironment().withProperty("AWS_ENDPOINT_URL","http://localhost:4566");
        assertThrows(IllegalStateException.class,()->AwsConfiguration.localEndpoint(env));
        env.setActiveProfiles("local");assertNotNull(AwsConfiguration.localEndpoint(env));
    }
}
