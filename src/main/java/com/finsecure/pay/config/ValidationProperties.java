package com.finsecure.pay.config;

import java.math.BigDecimal;
import java.util.List;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Business rules for transaction validation. Values come from application.yml and can be
 * overridden per environment through the Kubernetes ConfigMap (environment variables such as
 * FINSECURE_VALIDATION_MAXAMOUNT), so limits change without rebuilding the image.
 *
 * @param minAmount             smallest allowed amount (inclusive)
 * @param maxAmount             largest allowed amount for a single transaction (inclusive)
 * @param supportedCurrencies   ISO 4217 currency codes accepted by the platform
 * @param blockedAccounts       accounts that must never send or receive funds (sanctions / fraud list)
 * @param accountPattern        regular expression an account number must match
 * @param maxFutureSkewSeconds  how far in the future a transaction timestamp may be (clock skew allowance)
 */
@ConfigurationProperties(prefix = "finsecure.validation")
public record ValidationProperties(
        BigDecimal minAmount,
        BigDecimal maxAmount,
        List<String> supportedCurrencies,
        List<String> blockedAccounts,
        String accountPattern,
        long maxFutureSkewSeconds) {

    public ValidationProperties {
        minAmount = minAmount != null ? minAmount : new BigDecimal("0.01");
        maxAmount = maxAmount != null ? maxAmount : new BigDecimal("10000.00");
        supportedCurrencies = supportedCurrencies != null ? List.copyOf(supportedCurrencies) : List.of("SGD");
        blockedAccounts = blockedAccounts != null ? List.copyOf(blockedAccounts) : List.of();
        accountPattern = accountPattern != null && !accountPattern.isBlank() ? accountPattern : "^[0-9]{10,12}$";
        maxFutureSkewSeconds = maxFutureSkewSeconds > 0 ? maxFutureSkewSeconds : 300;
    }
}
