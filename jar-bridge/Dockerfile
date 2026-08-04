# Stage 1: Build
FROM gradle:8.14-jdk21 AS build
WORKDIR /app
COPY build.gradle.kts settings.gradle.kts ./
COPY gradle.properties ./
COPY src/ src/
RUN gradle fatJar --no-daemon

# Stage 2: Run
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/build/libs/*-all.jar app.jar
COPY config.yml ./

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /app --shell /usr/sbin/nologin streambox \
    && mkdir -p plugins data \
    && chown -R streambox:streambox /app

USER streambox

EXPOSE 9978

HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD curl --fail --silent http://127.0.0.1:9978/health >/dev/null || exit 1

ENTRYPOINT ["java"]
CMD ["-Xmx256m", "-jar", "app.jar"]
