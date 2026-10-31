package com.finsecure.pay.web;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

import com.finsecure.pay.config.AppProperties;
import com.finsecure.pay.model.TransactionRequest;
import com.finsecure.pay.model.ValidationResult;
import com.finsecure.pay.service.TransactionValidator;

/**
 * POST /validate - validates a transaction.
 * Returns 200 when approved, 422 when rejected, 401 when the API key is missing or wrong.
 */
@RestController
public class ValidationController {

    static final String API_KEY_HEADER = "X-API-Key";

    private final TransactionValidator validator;
    private final AppProperties appProperties;

    public ValidationController(TransactionValidator validator, AppProperties appProperties) {
        this.validator = validator;
        this.appProperties = appProperties;
    }

    @PostMapping(path = "/validate", consumes = "application/json", produces = "application/json")
    public ResponseEntity<?> validate(@RequestHeader(value = API_KEY_HEADER, required = false) String apiKey,
                                      @RequestBody TransactionRequest request) {
        if (appProperties.apiKeyRequired() && !matches(apiKey, appProperties.apiKey())) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("error", "UNAUTHORIZED", "message", "Missing or invalid " + API_KEY_HEADER));
        }
        ValidationResult result = validator.validate(request);
        HttpStatus status = result.valid() ? HttpStatus.OK : HttpStatus.UNPROCESSABLE_ENTITY;
        return ResponseEntity.status(status).body(result);
    }

    /** Constant-time comparison so response timing does not leak how much of the key was correct. */
    private static boolean matches(String provided, String expected) {
        if (provided == null) {
            return false;
        }
        return MessageDigest.isEqual(provided.getBytes(StandardCharsets.UTF_8),
                expected.getBytes(StandardCharsets.UTF_8));
    }
}
