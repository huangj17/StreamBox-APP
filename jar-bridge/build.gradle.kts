plugins {
    kotlin("jvm") version "2.3.20"
    kotlin("plugin.serialization") version "2.3.20"
    id("io.ktor.plugin") version "3.2.0"
    application
}

group = "com.streambox"
version = "1.0.0"

application {
    mainClass.set("com.streambox.bridge.ApplicationKt")
}

repositories {
    maven("https://maven.aliyun.com/repository/public")      // central + jcenter
    maven("https://maven.aliyun.com/repository/google")       // google
    maven("https://maven.aliyun.com/repository/gradle-plugin") // gradle plugins
    mavenCentral()  // 兜底
}

val ktorVersion = "3.2.0"

dependencies {
    // Ktor Server
    implementation("io.ktor:ktor-server-core:$ktorVersion")
    implementation("io.ktor:ktor-server-netty:$ktorVersion")
    implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    implementation("io.ktor:ktor-serialization-kotlinx-json:$ktorVersion")
    implementation("io.ktor:ktor-server-swagger:$ktorVersion")
    implementation("io.ktor:ktor-server-call-logging:$ktorVersion")

    // JSON
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")
    implementation("org.json:json:20250517")

    // YAML config
    implementation("org.yaml:snakeyaml:2.4")

    // HTTP client (JAR plugins may depend on it)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Gson (many JAR plugins depend on it)
    implementation("com.google.code.gson:gson:2.13.1")

    // Logging
    implementation("ch.qos.logback:logback-classic:1.5.18")

    // Test
    testImplementation("io.ktor:ktor-server-test-host:$ktorVersion")
    testImplementation("org.jetbrains.kotlin:kotlin-test:2.3.20")
}

kotlin {
    jvmToolchain(21)
}

// Build fat JAR
tasks.register<Jar>("fatJar") {
    archiveClassifier.set("all")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    manifest {
        attributes["Main-Class"] = "com.streambox.bridge.ApplicationKt"
    }
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) })
    with(tasks.jar.get())
}
