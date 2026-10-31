package com.finsecure.pay.model;

/**
 * A single failed validation rule.
 *
 * @param code    stable machine-readable rule code, e.g. LIMIT_EXCEEDED
 * @param message human-readable explanation
 */
public record Violation(String code, String message) {
}
