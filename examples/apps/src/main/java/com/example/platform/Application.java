package com.example.platform;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication(exclude = org.springframework.boot.data.redis.autoconfigure.DataRedisAutoConfiguration.class)
@EnableScheduling
public class Application {
    public static void main(String[] args) { SpringApplication.run(Application.class, args); }
}
