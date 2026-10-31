package com.finsecure.pay;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * FinSecure Pay transaction validation API.
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class FinSecurePayApplication {

    public static void main(String[] args) {
        SpringApplication.run(FinSecurePayApplication.class, args);
    }
}
