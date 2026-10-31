package com.finsecure.pay.health;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.boot.actuate.health.Status;

import com.finsecure.pay.config.AppProperties;

class ReleaseHealthIndicatorTest {

    @Test
    void upForNormalRelease() {
        AppProperties app = new AppProperties("test", "test", "", new AppProperties.Release(false));
        assertThat(new ReleaseHealthIndicator(app).health().getStatus()).isEqualTo(Status.UP);
    }

    @Test
    void downWhenReleaseIsFlaggedUnhealthy() {
        AppProperties app = new AppProperties("test", "test", "", new AppProperties.Release(true));
        assertThat(new ReleaseHealthIndicator(app).health().getStatus()).isEqualTo(Status.DOWN);
    }
}
