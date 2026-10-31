# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# FinSecure Pay - multi-stage build
#   Stage 1 compiles with the Maven wrapper (same Maven version everywhere).
#   Stage 2 is a small JRE-only image that runs as a non-root user.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src

# Copy the build definition first so dependency downloads are cached between builds
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN chmod +x mvnw && ./mvnw -B -ntp -q dependency:go-offline

COPY src/ src/
# Tests run in the CI pipeline's Test stage; the image build only packages the application
RUN ./mvnw -B -ntp -q package -DskipTests

# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre-alpine

ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="finsecure-pay" \
      org.opencontainers.image.description="FinSecure Pay transaction validation API" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}"

RUN addgroup -S app && adduser -S -G app -u 10001 app
WORKDIR /app
COPY --from=build --chown=10001:10001 /src/target/finsecure-pay.jar /app/app.jar

USER 10001
EXPOSE 8080 8081
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError -Djava.io.tmpdir=/tmp"

HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
