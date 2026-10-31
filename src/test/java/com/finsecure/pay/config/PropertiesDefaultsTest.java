package com.finsecure.pay.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.math.BigDecimal;
import java.util.List;

import org.junit.jupiter.api.Test;

class PropertiesDefaultsTest {

    @Test
    void validationPropertiesFallBackToSafeDefaults() {
        ValidationProperties props = new ValidationProperties(null, null, null, null, " ", 0);

        assertThat(props.minAmount()).isEqualByComparingTo("0.01");
        assertThat(props.maxAmount()).isEqualByComparingTo("10000.00");
        assertThat(props.supportedCurrencies()).containsExactly("SGD");
        assertThat(props.blockedAccounts()).isEmpty();
        assertThat(props.accountPattern()).isEqualTo("^[0-9]{10,12}$");
        assertThat(props.maxFutureSkewSeconds()).isEqualTo(300);
    }

    @Test
    void validationPropertiesKeepConfiguredValues() {
        ValidationProperties props = new ValidationProperties(new BigDecimal("1"), new BigDecimal("500"),
                List.of("USD"), List.of("111111111111"), "^[0-9]{12}$", 60);

        assertThat(props.maxAmount()).isEqualByComparingTo("500");
        assertThat(props.supportedCurrencies()).containsExactly("USD");
        assertThat(props.blockedAccounts()).containsExactly("111111111111");
        assertThat(props.maxFutureSkewSeconds()).isEqualTo(60);
    }

    @Test
    void appPropertiesDefaults() {
        AppProperties app = new AppProperties(null, null, null, null);

        assertThat(app.environment()).isEqualTo("local");
        assertThat(app.build()).isEqualTo("local");
        assertThat(app.apiKeyRequired()).isFalse();
        assertThat(app.release().simulateUnhealthy()).isFalse();
    }

    @Test
    void apiKeyRequiredWhenConfigured() {
        assertThat(new AppProperties("p", "b", "key", null).apiKeyRequired()).isTrue();
    }
}
