package com.finsecure.pay.model;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

/**
 * Incoming transaction to validate.
 *
 * @param transactionId      unique identifier supplied by the caller
 * @param sourceAccount      account the money is taken from
 * @param destinationAccount account the money is sent to
 * @param amount             transaction amount
 * @param currency           ISO 4217 currency code, e.g. SGD
 * @param timestamp          optional time the transaction was created (ISO-8601)
 */
public record TransactionRequest(
        String transactionId,
        String sourceAccount,
        String destinationAccount,
        BigDecimal amount,
        String currency,
        OffsetDateTime timestamp) {
}
