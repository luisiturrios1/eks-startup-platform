package com.example.platform;

import org.flywaydb.core.Flyway;
import org.springframework.boot.ApplicationRunner;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.core.env.Environment;

@Configuration
@Profile("migration")
class Migrations {
    @Bean ApplicationRunner migrate(RotatingDataSource source, Environment env, ConfigurableApplicationContext context) {
        return args -> {
            Flyway.configure().dataSource(source).locations("classpath:db/migration/"+env.getRequiredProperty("DB_ENGINE"))
                .cleanDisabled(true).validateMigrationNaming(true).load().migrate();
            context.close();
        };
    }
}
