package com.finsecure.pay.health;

import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.stereotype.Component;

import com.finsecure.pay.config.AppProperties;

/**
 * Part of the readiness group (see application.yml). Normally UP. When the release flag
 * finsecure.release.simulate-unhealthy is true it reports DOWN, so Kubernetes never routes
 * traffic to the new pods, the rollout times out and the pipeline rolls back automatically.
 * Contributor name: "release".
 */
@Component
public class ReleaseHealthIndicator implements HealthIndicator {

    private final AppProperties appProperties;

    public ReleaseHealthIndicator(AppProperties appProperties) {
        this.appProperties = appProperties;
    }

    @Override
    public Health health() {
        if (appProperties.release().simulateUnhealthy()) {
            return Health.down().withDetail("reason", "Release flagged unhealthy (rollback demonstration)").build();
        }
        return Health.up().build();
    }
}
