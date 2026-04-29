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

RUN mkdir -p plugins data

EXPOSE 9978

ENTRYPOINT ["java"]
CMD ["-Xmx256m", "-jar", "app.jar"]
