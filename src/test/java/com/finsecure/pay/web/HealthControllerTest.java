package com.finsecure.pay.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.Properties;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.boot.info.BuildProperties;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import com.finsecure.pay.config.AppProperties;

class HealthControllerTest {

    private static final AppProperties APP = new AppProperties("production", "b42-abc1234", "", null);

    @Test
    void reportsUpWithVersionAndBuild() throws Exception {
        Properties info = new Properties();
        info.setProperty("version", "1.2.3");
        StaticListableBeanFactory beans = new StaticListableBeanFactory();
        beans.addBean("buildProperties", new BuildProperties(info));

        MockMvc mvc = MockMvcBuilders.standaloneSetup(
                new HealthController(APP, beans.getBeanProvider(BuildProperties.class))).build();

        mvc.perform(get("/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"))
                .andExpect(jsonPath("$.service").value("finsecure-pay"))
                .andExpect(jsonPath("$.version").value("1.2.3"))
                .andExpect(jsonPath("$.build").value("b42-abc1234"))
                .andExpect(jsonPath("$.environment").value("production"));
    }

    @Test
    void reportsUnknownVersionWhenBuildInfoIsMissing() throws Exception {
        StaticListableBeanFactory empty = new StaticListableBeanFactory();
        MockMvc mvc = MockMvcBuilders.standaloneSetup(
                new HealthController(APP, empty.getBeanProvider(BuildProperties.class))).build();

        mvc.perform(get("/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.version").value("unknown"));
    }
}
