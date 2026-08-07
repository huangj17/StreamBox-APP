plugins {
    kotlin("jvm") version "2.3.20"
    kotlin("plugin.serialization") version "2.3.20"
    application
}

group = "com.streambox"
version = "2.0.0"

application {
    mainClass.set("com.streambox.bridge.ApplicationKt")
}

val ktorVersion = "3.5.2"
val coroutinesVersion = "1.10.2"
val nettyVersion = "4.2.16.Final"

configurations.configureEach {
    exclude(group = "org.fusesource.jansi", module = "jansi")
    resolutionStrategy.eachDependency {
        if (requested.group == "io.netty") {
            useVersion(nettyVersion)
            because("Netty 4.2.2 contains remotely reachable HTTP request-smuggling and DoS vulnerabilities")
        }
    }
}

dependencyLocking {
    lockAllConfigurations()
}

dependencies {
    // Ktor Server
    implementation("io.ktor:ktor-server-core:$ktorVersion")
    implementation("io.ktor:ktor-server-netty:$ktorVersion")
    implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    implementation("io.ktor:ktor-serialization-kotlinx-json:$ktorVersion")
    implementation("io.ktor:ktor-server-swagger:$ktorVersion")
    // Jansi is excluded globally: distroless + noexec /tmp does not need terminal colors.
    implementation("io.ktor:ktor-server-call-logging:$ktorVersion")

    // Spider、CMS 和图片代理调用使用协程隔离阻塞 I/O。
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:$coroutinesVersion")

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
    implementation("ch.qos.logback:logback-classic:1.5.37")

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
