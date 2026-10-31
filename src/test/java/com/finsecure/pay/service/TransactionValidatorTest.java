package com.finsecure.pay.service;

import static org.assertj.core.api.Assertions.assertThat;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import com.finsecure.pay.config.ValidationProperties;
import com.finsecure.pay.model.TransactionRequest;
import com.finsecure.pay.model.ValidationResult;
import com.finsecure.pay.model.Violation;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;

class TransactionValidatorTest {

    private static final Instant NOW = Instant.parse("2026-11-01T10:00:00Z");

    private SimpleMeterRegistry registry;
    private TransactionValidator validator;

    @BeforeEach
    void setUp() {
        ValidationProperties props = new ValidationProperties(
                new BigDecimal("0.01"), new BigDecimal("10000.00"),
                List.of("SGD", "USD", "EUR"), List.of("999999999999"),
                "^[0-9]{10,12}$", 300);
        registry = new SimpleMeterRegistry();
        validator = new TransactionValidator(props, registry, Clock.fixed(NOW, ZoneOffset.UTC));
    }

    private static TransactionRequest tx(String amount, String currency, String source, String destination) {
        return new TransactionRequest("TXN-1001", source, destination,
                amount == null ? null : new BigDecimal(amount), currency, null);
    }

    private static TransactionRequest valid() {
        return tx("250.50", "SGD", "1234567890", "9876543210");
    }

    private static List<String> codes(ValidationResult result) {
        return result.violations().stream().map(Violation::code).toList();
    }

    @Test
    @DisplayName("A well-formed transaction within limits is approved")
    void approvesValidTransaction() {
        ValidationResult result = validator.validate(valid());

        assertThat(result.valid()).isTrue();
        assertThat(result.status()).isEqualTo(ValidationResult.APPROVED);
        assertThat(result.violations()).isEmpty();
        assertThat(result.transactionId()).isEqualTo("TXN-1001");
    }

    @Test
    @DisplayName("An amount exactly at the limit is approved (boundary)")
    void approvesAmountAtLimit() {
        assertThat(validator.validate(tx("10000.00", "USD", "1234567890", "9876543210")).valid()).isTrue();
    }

    @Test
    @DisplayName("An amount above the single-transaction limit is rejected")
    void rejectsAmountAboveLimit() {
        ValidationResult result = validator.validate(tx("10000.01", "SGD", "1234567890", "9876543210"));

        assertThat(result.valid()).isFalse();
        assertThat(result.status()).isEqualTo(ValidationResult.REJECTED);
        assertThat(codes(result)).containsExactly(TransactionValidator.LIMIT_EXCEEDED);
    }

    @ParameterizedTest(name = "amount {0} is rejected")
    @ValueSource(strings = {"0", "-5.00", "0.001"})
    void rejectsZeroNegativeOrTooSmallAmounts(String amount) {
        assertThat(codes(validator.validate(tx(amount, "SGD", "1234567890", "9876543210"))))
                .contains(TransactionValidator.INVALID_AMOUNT);
    }

    @Test
    @DisplayName("More than two decimal places is rejected")
    void rejectsTooManyDecimalPlaces() {
        assertThat(codes(validator.validate(tx("10.123", "SGD", "1234567890", "9876543210"))))
                .containsExactly(TransactionValidator.INVALID_PRECISION);
    }

    @Test
    @DisplayName("Trailing zeros do not count as extra precision")
    void acceptsTrailingZeros() {
        assertThat(validator.validate(tx("10.5000", "SGD", "1234567890", "9876543210")).valid()).isTrue();
    }

    @Test
    @DisplayName("An unsupported currency is rejected")
    void rejectsUnsupportedCurrency() {
        assertThat(codes(validator.validate(tx("10.00", "JPY", "1234567890", "9876543210"))))
                .containsExactly(TransactionValidator.UNSUPPORTED_CURRENCY);
    }

    @Test
    @DisplayName("Currency matching is case-insensitive")
    void acceptsLowerCaseCurrency() {
        assertThat(validator.validate(tx("10.00", "sgd", "1234567890", "9876543210")).valid()).isTrue();
    }

    @ParameterizedTest(name = "account \"{0}\" is rejected")
    @ValueSource(strings = {"12345", "ABCDEFGHIJ", "1234567890123"})
    void rejectsInvalidAccountFormat(String account) {
        assertThat(codes(validator.validate(tx("10.00", "SGD", account, "9876543210"))))
                .containsExactly(TransactionValidator.INVALID_ACCOUNT);
    }

    @Test
    @DisplayName("Sending money to the same account is rejected")
    void rejectsSameAccount() {
        assertThat(codes(validator.validate(tx("10.00", "SGD", "1234567890", "1234567890"))))
                .containsExactly(TransactionValidator.SAME_ACCOUNT);
    }

    @Test
    @DisplayName("A blocked destination account is rejected")
    void rejectsBlockedDestination() {
        assertThat(codes(validator.validate(tx("10.00", "SGD", "1234567890", "999999999999"))))
                .containsExactly(TransactionValidator.BLOCKED_ACCOUNT);
    }

    @Test
    @DisplayName("A blocked source account is rejected")
    void rejectsBlockedSource() {
        assertThat(codes(validator.validate(tx("10.00", "SGD", "999999999999", "1234567890"))))
                .containsExactly(TransactionValidator.BLOCKED_ACCOUNT);
    }

    @Test
    @DisplayName("Missing fields are all reported")
    void reportsMissingFields() {
        TransactionRequest empty = new TransactionRequest(null, null, null, null, null, null);

        ValidationResult result = validator.validate(empty);

        assertThat(result.valid()).isFalse();
        assertThat(result.violations()).hasSize(5)
                .allMatch(v -> v.code().equals(TransactionValidator.REQUIRED_FIELD));
    }

    @Test
    @DisplayName("A null request is rejected safely")
    void rejectsNullRequest() {
        ValidationResult result = validator.validate(null);

        assertThat(result.valid()).isFalse();
        assertThat(codes(result)).containsExactly(TransactionValidator.REQUIRED_FIELD);
    }

    @Test
    @DisplayName("Every failed rule is reported, not just the first")
    void reportsAllViolations() {
        ValidationResult result = validator.validate(tx("20000.999", "JPY", "1234567890", "1234567890"));

        assertThat(codes(result)).containsExactlyInAnyOrder(
                TransactionValidator.LIMIT_EXCEEDED, TransactionValidator.INVALID_PRECISION,
                TransactionValidator.UNSUPPORTED_CURRENCY, TransactionValidator.SAME_ACCOUNT);
    }

    @Test
    @DisplayName("A timestamp far in the future is rejected, small clock skew is allowed")
    void checksTimestamp() {
        OffsetDateTime inSkew = OffsetDateTime.ofInstant(NOW.plusSeconds(120), ZoneOffset.UTC);
        OffsetDateTime tooFar = OffsetDateTime.ofInstant(NOW.plusSeconds(3600), ZoneOffset.UTC);

        TransactionRequest ok = new TransactionRequest("TXN-1", "1234567890", "9876543210",
                new BigDecimal("1.00"), "SGD", inSkew);
        TransactionRequest future = new TransactionRequest("TXN-2", "1234567890", "9876543210",
                new BigDecimal("1.00"), "SGD", tooFar);

        assertThat(validator.validate(ok).valid()).isTrue();
        assertThat(codes(validator.validate(future))).containsExactly(TransactionValidator.FUTURE_TIMESTAMP);
    }

    @Test
    @DisplayName("Decisions are recorded as Prometheus metrics")
    void recordsMetrics() {
        validator.validate(valid());
        validator.validate(valid());
        validator.validate(tx("10.00", "JPY", "1234567890", "9876543210"));

        assertThat(registry.get("finsecure.validations").tag("result", "approved").counter().count()).isEqualTo(2.0);
        assertThat(registry.get("finsecure.validations").tag("result", "rejected").counter().count()).isEqualTo(1.0);
        assertThat(registry.get("finsecure.validation.rejections").tag("rule", "UNSUPPORTED_CURRENCY")
                .counter().count()).isEqualTo(1.0);
    }

    @Test
    @DisplayName("Account numbers are masked and unsafe ids are not logged")
    void masksSensitiveValuesForLogs() {
        assertThat(TransactionValidator.mask("1234567890")).isEqualTo("******7890");
        assertThat(TransactionValidator.mask("12")).isEqualTo("****");
        assertThat(TransactionValidator.mask(null)).isEqualTo("****");
        assertThat(TransactionValidator.safeForLog("TXN-1001")).isEqualTo("TXN-1001");
        assertThat(TransactionValidator.safeForLog("bad\nINFO fake log line")).isEqualTo("<invalid-id>");
        assertThat(TransactionValidator.safeForLog(null)).isEqualTo("<invalid-id>");
    }
}
