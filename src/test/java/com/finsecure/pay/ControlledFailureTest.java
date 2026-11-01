package com.finsecure.pay;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

/** Deliberately failing test: demonstrates that the pipeline stops before deployment. */
class ControlledFailureTest {

    @Test
    void controlledFailureForPipelineDemo() {
        assertThat(1 + 1).as("Controlled failure for the capstone demo").isEqualTo(3);
    }
}
