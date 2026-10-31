package com.finsecure.pay.web;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.info.BuildProperties;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import com.finsecure.pay.config.AppProperties;

/**
 * GET /health - public, lightweight health endpoint for users, load balancers and smoke tests.
 * Reports the running version so rollouts and rollbacks are visible. Kubernetes probes use the
 * richer Actuator endpoints (/actuator/health/liveness and /readiness) on the management port.
 */
@RestController
public class HealthController {

    private final AppProperties appProperties;
    private final String version;

    public HealthController(AppProperties appProperties, ObjectProvider<BuildProperties> buildProperties) {
        this.appProperties = appProperties;
        BuildProperties bp = buildProperties.getIfAvailable();
        this.version = bp != null ? bp.getVersion() : "unknown";
    }

    @GetMapping(path = "/health", produces = "application/json")
    public Map<String, Object> health() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", "UP");
        body.put("service", "finsecure-pay");
        body.put("version", version);
        body.put("build", appProperties.build());
        body.put("environment", appProperties.environment());
        body.put("timestamp", Instant.now().toString());
        return body;
    }
}
