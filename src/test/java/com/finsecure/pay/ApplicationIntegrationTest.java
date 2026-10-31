package com.finsecure.pay;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.actuate.observability.AutoConfigureObservability;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;

/**
 * Starts the full application on random ports and checks the wiring end to end:
 * configuration binding, endpoints, probes and the Prometheus metrics endpoint.
 * (@AutoConfigureObservability re-enables metrics export, which Spring Boot turns off in tests by default.)
 */
@AutoConfigureObservability
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {"management.server.port=0", "finsecure.api-key=it-key",
                      "finsecure.release.simulate-unhealthy=false"})
class ApplicationIntegrationTest {

    @Autowired
    private TestRestTemplate rest;

    @LocalManagementPort
    private int managementPort;

    @Test
    void publicHealthEndpointIsUp() {
        ResponseEntity<String> response = rest.getForEntity("/health", String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).contains("\"status\":\"UP\"").contains("finsecure-pay");
    }

    @Test
    void validateEndpointAppliesRulesAndApiKey() {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        headers.set("X-API-Key", "it-key");
        String body = """
                {"transactionId":"TXN-IT-1","sourceAccount":"1234567890","destinationAccount":"9876543210",
                 "amount":99.99,"currency":"EUR"}""";

        ResponseEntity<String> ok = rest.postForEntity("/validate", new HttpEntity<>(body, headers), String.class);
        ResponseEntity<String> noKey = rest.postForEntity("/validate",
                new HttpEntity<>(body, jsonOnly()), String.class);

        assertThat(ok.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(ok.getBody()).contains("APPROVED");
        assertThat(noKey.getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    @Test
    void probesAndMetricsAreServedOnTheManagementPort() {
        String base = "http://localhost:" + managementPort + "/actuator";

        assertThat(rest.getForEntity(base + "/health/liveness", String.class).getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(rest.getForEntity(base + "/health/readiness", String.class).getStatusCode()).isEqualTo(HttpStatus.OK);

        ResponseEntity<String> metrics = rest.getForEntity(base + "/prometheus", String.class);
        assertThat(metrics.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(metrics.getBody()).contains("finsecure_validations_total");
    }

    private static HttpHeaders jsonOnly() {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_JSON);
        return headers;
    }
}
