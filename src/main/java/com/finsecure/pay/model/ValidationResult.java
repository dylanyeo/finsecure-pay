package com.finsecure.pay.model;

import java.util.List;

/**
 * Outcome of validating a transaction.
 *
 * @param transactionId the transaction that was validated
 * @param valid         true when every rule passed
 * @param status        APPROVED or REJECTED
 * @param violations    the rules that failed (empty when approved)
 */
public record ValidationResult(String transactionId, boolean valid, String status, List<Violation> violations) {

    public static final String APPROVED = "APPROVED";
    public static final String REJECTED = "REJECTED";

    public static ValidationResult of(String transactionId, List<Violation> violations) {
        boolean ok = violations.isEmpty();
        return new ValidationResult(transactionId, ok, ok ? APPROVED : REJECTED, List.copyOf(violations));
    }
}
