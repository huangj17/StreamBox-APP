# Stage 1: Build
FROM gradle:8.14.3-jdk21@sha256:21bd311ed01360c189b8870c6b6e988199ff10f72d445d02fb39d3cff9da91d7 AS build
WORKDIR /app
COPY build.gradle.kts settings.gradle.kts ./
COPY gradle.properties ./
COPY gradle.lockfile ./
COPY gradle/ gradle/
COPY src/ src/
RUN gradle fatJar --no-daemon

# Stage 2: Run
FROM gcr.io/distroless/java21-debian12:nonroot@sha256:7e37784d94dccbf5ccb195c73b295f5ad00cd266512dfbac12eb9c3c28f8077d
WORKDIR /app
COPY --from=build --chown=nonroot:nonroot /app/build/libs/*-all.jar app.jar
COPY --chown=nonroot:nonroot config.yml ./

USER nonroot:nonroot

EXPOSE 9978

HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD ["/usr/bin/java", "-cp", "app.jar", "com.streambox.bridge.Healthcheck"]

ENTRYPOINT ["/usr/bin/java"]
CMD ["-Xmx256m", "-jar", "app.jar"]
