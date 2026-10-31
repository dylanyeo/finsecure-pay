package com.finsecure.pay.service;

import java.math.BigDecimal;
import java.time.Clock;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import com.finsecure.pay.config.ValidationProperties;
import com.finsecure.pay.model.TransactionRequest;
import com.finsecure.pay.model.ValidationResult;
import com.finsecure.pay.model.Violation;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;

/**
 * Applies the FinSecure Pay business rules to a transaction.
 *
 * <p>All rules are evaluated (not fail-fast) so the caller receives every reason a transaction
 * was rejected. Each decision is counted in Micrometer metrics, which Prometheus scrapes and
 * Grafana displays, and is logged with masked account numbers for troubleshooting.
 */
@Service
public class TransactionValidator {

    public static final String REQUIRED_FIELD = "REQUIRED_FIELD";
    public static final String INVALID_AMOUNT = "INVALID_AMOUNT";
    public static final String LIMIT_EXCEEDED = "LIMIT_EXCEEDED";
    public static final String INVALID_PRECISION = "INVALID_PRECISION";
    public static final String UNSUPPORTED_CURRENCY = "UNSUPPORTED_CURRENCY";
    public static final String INVALID_ACCOUNT = "INVALID_ACCOUNT";
    public static final String SAME_ACCOUNT = "SAME_ACCOUNT";
    public static final String BLOCKED_ACCOUNT = "BLOCKED_ACCOUNT";
    public static final String FUTURE_TIMESTAMP = "FUTURE_TIMESTAMP";

    static final String METRIC_VALIDATIONS = "finsecure.validations";
    static final String METRIC_REJECTIONS = "finsecure.validation.rejections";

    private static final Logger log = LoggerFactory.getLogger(TransactionValidator.class);

    private final ValidationProperties props;
    private final MeterRegistry registry;
    private final Clock clock;
    private final Pattern accountPattern;
    private final Counter approvedCounter;
    private final Counter rejectedCounter;

    @Autowired
    public TransactionValidator(ValidationProperties props, MeterRegistry registry) {
        this(props, registry, Clock.systemUTC());
    }

    TransactionValidator(ValidationProperties props, MeterRegistry registry, Clock clock) {
        this.props = props;
        this.registry = registry;
        this.clock = clock;
        this.accountPattern = Pattern.compile(props.accountPattern());
        this.approvedCounter = Counter.builder(METRIC_VALIDATIONS)
                .description("Transaction validation decisions")
                .tag("result", "approved")
                .register(registry);
        this.rejectedCounter = Counter.builder(METRIC_VALIDATIONS)
                .description("Transaction validation decisions")
                .tag("result", "rejected")
                .register(registry);
    }

    public ValidationResult validate(TransactionRequest tx) {
        List<Violation> violations = new ArrayList<>();

        if (tx == null) {
            violations.add(new Violation(REQUIRED_FIELD, "Request body is required"));
            return record(null, violations);
        }

        if (isBlank(tx.transactionId())) {
            violations.add(new Violation(REQUIRED_FIELD, "transactionId is required"));
        }

        checkAmount(tx.amount(), violations);
        checkCurrency(tx.currency(), violations);
        checkAccounts(tx.sourceAccount(), tx.destinationAccount(), violations);
        checkTimestamp(tx.timestamp(), violations);

        return record(tx, violations);
    }

    private void checkAmount(BigDecimal amount, List<Violation> violations) {
        if (amount == null) {
            violations.add(new Violation(REQUIRED_FIELD, "amount is required"));
            return;
        }
        if (amount.compareTo(props.minAmount()) < 0) {
            violations.add(new Violation(INVALID_AMOUNT,
                    "amount must be at least " + props.minAmount().toPlainString()));
        }
        if (amount.compareTo(props.maxAmount()) > 0) {
            violations.add(new Violation(LIMIT_EXCEEDED,
                    "amount exceeds the single-transaction limit of " + props.maxAmount().toPlainString()));
        }
        if (amount.stripTrailingZeros().scale() > 2) {
            violations.add(new Violation(INVALID_PRECISION, "amount must have at most 2 decimal places"));
        }
    }

    private void checkCurrency(String currency, List<Violation> violations) {
        if (isBlank(currency)) {
            violations.add(new Violation(REQUIRED_FIELD, "currency is required"));
            return;
        }
        String code = currency.trim().toUpperCase(Locale.ROOT);
        boolean supported = props.supportedCurrencies().stream()
                .anyMatch(c -> c.trim().equalsIgnoreCase(code));
        if (!supported) {
            violations.add(new Violation(UNSUPPORTED_CURRENCY,
                    "currency " + code + " is not supported; allowed: " + String.join(",", props.supportedCurrencies())));
        }
    }

    private void checkAccounts(String source, String destination, List<Violation> violations) {
        boolean sourceOk = checkAccountFormat("sourceAccount", source, violations);
        boolean destinationOk = checkAccountFormat("destinationAccount", destination, violations);

        if (sourceOk && destinationOk && source.equals(destination)) {
            violations.add(new Violation(SAME_ACCOUNT, "sourceAccount and destinationAccount must be different"));
        }
        if (sourceOk && isBlocked(source)) {
            violations.add(new Violation(BLOCKED_ACCOUNT, "sourceAccount is blocked"));
        }
        if (destinationOk && isBlocked(destination)) {
            violations.add(new Violation(BLOCKED_ACCOUNT, "destinationAccount is blocked"));
        }
    }

    private boolean checkAccountFormat(String field, String account, List<Violation> violations) {
        if (isBlank(account)) {
            violations.add(new Violation(REQUIRED_FIELD, field + " is required"));
            return false;
        }
        if (!accountPattern.matcher(account).matches()) {
            violations.add(new Violation(INVALID_ACCOUNT, field + " has an invalid format"));
            return false;
        }
        return true;
    }

    private boolean isBlocked(String account) {
        return props.blockedAccounts().stream().anyMatch(b -> b.trim().equals(account));
    }

    private void checkTimestamp(OffsetDateTime timestamp, List<Violation> violations) {
        if (timestamp == null) {
            return; // optional field
        }
        OffsetDateTime latestAllowed = OffsetDateTime.now(clock).plusSeconds(props.maxFutureSkewSeconds());
        if (timestamp.isAfter(latestAllowed)) {
            violations.add(new Violation(FUTURE_TIMESTAMP, "timestamp is in the future"));
        }
    }

    private ValidationResult record(TransactionRequest tx, List<Violation> violations) {
        String id = tx != null ? tx.transactionId() : null;
        ValidationResult result = ValidationResult.of(id, violations);
        String safeId = safeForLog(id);
        if (result.valid()) {
            approvedCounter.increment();
            log.info("Transaction {} APPROVED source={} destination={}", safeId,
                    mask(tx != null ? tx.sourceAccount() : null), mask(tx != null ? tx.destinationAccount() : null));
        } else {
            rejectedCounter.increment();
            List<String> codes = violations.stream().map(Violation::code).distinct().toList();
            codes.forEach(code -> Counter.builder(METRIC_REJECTIONS)
                    .description("Rejected transactions by failed rule")
                    .tag("rule", code)
                    .register(registry)
                    .increment());
            log.warn("Transaction {} REJECTED rules={}", safeId, codes);
        }
        return result;
    }

    /**
     * Only logs identifiers made of safe characters, preventing log injection (e.g. fake log lines via CR/LF).
     */
    static String safeForLog(String transactionId) {
        if (transactionId != null && transactionId.matches("[A-Za-z0-9_-]{1,64}")) {
            return transactionId;
        }
        return "<invalid-id>";
    }

    /** Masks an account number so logs never contain the full value, e.g. ********1234. */
    static String mask(String account) {
        if (account == null || !account.matches("[0-9]{5,34}")) {
            return "****";
        }
        return "*".repeat(account.length() - 4) + account.substring(account.length() - 4);
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
