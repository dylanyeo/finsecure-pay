package com.finsecure.pay.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.math.BigDecimal;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import com.finsecure.pay.config.AppProperties;
import com.finsecure.pay.config.ValidationProperties;
import com.finsecure.pay.service.TransactionValidator;

import io.micrometer.core.instrument.simple.SimpleMeterRegistry;

class ValidationControllerTest {

    private static final String VALID_JSON = """
            {"transactionId":"TXN-2001","sourceAccount":"1234567890","destinationAccount":"9876543210",
             "amount":150.75,"currency":"SGD"}""";

    private static final String OVER_LIMIT_JSON = """
            {"transactionId":"TXN-2002","sourceAccount":"1234567890","destinationAccount":"9876543210",
             "amount":50000,"currency":"SGD"}""";

    private MockMvc mockMvc(String apiKey) {
        ValidationProperties props = new ValidationProperties(new BigDecimal("0.01"), new BigDecimal("10000"),
                List.of("SGD"), List.of(), "^[0-9]{10,12}$", 300);
        AppProperties app = new AppProperties("test", "test", apiKey, null);
        TransactionValidator validator = new TransactionValidator(props, new SimpleMeterRegistry());
        return MockMvcBuilders.standaloneSetup(new ValidationController(validator, app))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();
    }

    @Test
    void approvedTransactionReturns200() throws Exception {
        mockMvc("").perform(post("/validate").contentType(MediaType.APPLICATION_JSON).content(VALID_JSON))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.valid").value(true))
                .andExpect(jsonPath("$.status").value("APPROVED"))
                .andExpect(jsonPath("$.transactionId").value("TXN-2001"));
    }

    @Test
    void rejectedTransactionReturns422WithReasons() throws Exception {
        mockMvc("").perform(post("/validate").contentType(MediaType.APPLICATION_JSON).content(OVER_LIMIT_JSON))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.valid").value(false))
                .andExpect(jsonPath("$.status").value("REJECTED"))
                .andExpect(jsonPath("$.violations[0].code").value("LIMIT_EXCEEDED"));
    }

    @Test
    void malformedJsonReturns400() throws Exception {
        mockMvc("").perform(post("/validate").contentType(MediaType.APPLICATION_JSON).content("{not json"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("MALFORMED_REQUEST"));
    }

    @Test
    void wrongContentTypeReturns415() throws Exception {
        mockMvc("").perform(post("/validate").contentType(MediaType.TEXT_PLAIN).content("hello"))
                .andExpect(status().isUnsupportedMediaType())
                .andExpect(jsonPath("$.error").value("UNSUPPORTED_MEDIA_TYPE"));
    }

    @Test
    void missingApiKeyReturns401WhenKeyIsConfigured() throws Exception {
        mockMvc("s3cret-test-key").perform(post("/validate").contentType(MediaType.APPLICATION_JSON).content(VALID_JSON))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error").value("UNAUTHORIZED"));
    }

    @Test
    void wrongApiKeyReturns401() throws Exception {
        mockMvc("s3cret-test-key").perform(post("/validate").header("X-API-Key", "guess")
                        .contentType(MediaType.APPLICATION_JSON).content(VALID_JSON))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void correctApiKeyIsAccepted() throws Exception {
        mockMvc("s3cret-test-key").perform(post("/validate").header("X-API-Key", "s3cret-test-key")
                        .contentType(MediaType.APPLICATION_JSON).content(VALID_JSON))
                .andExpect(status().isOk());
    }
}
