package com.finsecure.pay.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Operational settings.
 *
 * @param environment human-readable environment name (local, production, ...) shown by /health
 * @param build       build identifier injected by the pipeline (build number and git commit)
 * @param apiKey      optional API key for /validate; injected from a Kubernetes Secret, empty disables the check
 * @param release     release behaviour switches
 */
@ConfigurationProperties(prefix = "finsecure")
public record AppProperties(String environment, String build, String apiKey, Release release) {

    public AppProperties {
        environment = environment != null ? environment : "local";
        build = build != null ? build : "local";
        apiKey = apiKey != null ? apiKey : "";
        release = release != null ? release : new Release(false);
    }

    /**
     * @param simulateUnhealthy when true the readiness probe reports DOWN. Used only to demonstrate that a
     *                          broken release never receives traffic and is rolled back automatically.
     */
    public record Release(boolean simulateUnhealthy) {
    }

    public boolean apiKeyRequired() {
        return !apiKey.isBlank();
    }
}
