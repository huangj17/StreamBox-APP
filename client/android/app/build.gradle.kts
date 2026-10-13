import org.gradle.api.tasks.compile.JavaCompile
import org.gradle.jvm.tasks.Jar

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.streambox.streambox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.streambox.streambox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "com.streambox.streambox.spider.HostInstrumentation"
        // 仅打包 ARM 架构：x86_64 只用于 Android 模拟器，且模拟器无法软件渲染播放视频。
        // Flutter 引擎的 ABI 由 --target-platform 控制（默认 release 全 ABI），
        // 此处通过 abiFilters 让 Flutter Gradle plugin 仅产出 arm 变体。
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    // 过滤第三方 AAR（如 media_kit_libs_android_video）里的预编译 JNI .so —
    // ndk.abiFilters 不会作用到这些已编译的 native 库，需要在 packaging 阶段排除。
    packaging {
        jniLibs {
            excludes += setOf("**/x86/**", "**/x86_64/**")
        }
    }

    val releaseKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
    val releaseKeystorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
    val releaseKeyAlias = System.getenv("ANDROID_KEY_ALIAS")
    val releaseKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")
    val hasReleaseSigning = listOf(
        releaseKeystorePath,
        releaseKeystorePassword,
        releaseKeyAlias,
        releaseKeyPassword,
    ).all { !it.isNullOrBlank() }
    val hasPartialReleaseSigning = listOf(
        releaseKeystorePath,
        releaseKeystorePassword,
        releaseKeyAlias,
        releaseKeyPassword,
    ).any { !it.isNullOrBlank() } && !hasReleaseSigning
    if (hasPartialReleaseSigning) {
        throw GradleException("Android release signing credentials are incomplete")
    }

    gradle.taskGraph.whenReady {
        val releaseRequested = allTasks.any {
            it.name.contains("release", ignoreCase = true)
        }
        if (releaseRequested && !hasReleaseSigning) {
            throw GradleException(
                "Release builds require ANDROID_KEYSTORE_PATH, " +
                    "ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD"
            )
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Release artifacts are deliberately left unsigned when credentials are
            // absent. CI supplies a persistent keystore and refuses to publish unless
            // the resulting certificate fingerprint matches the configured value.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// The fixture is compiled into a separate DEX archive, never the app's classes.
// Instrumentation therefore tests actual dynamic loading rather than a class
// accidentally found in the parent loader.
android.sourceSets.getByName("androidTest").assets.srcDir(layout.buildDirectory.dir("spider-fixture"))
val compileSpiderFixture = tasks.register<JavaCompile>("compileSpiderFixture") {
    dependsOn("compileDebugJavaWithJavac")
    source(fileTree("test-fixtures") { include("**/*.java") })
    classpath = files(android.bootClasspath,
        layout.buildDirectory.dir("intermediates/javac/debug/compileDebugJavaWithJavac/classes"),
        providers.provider { tasks.named<JavaCompile>("compileDebugJavaWithJavac").get().classpath })
    destinationDirectory.set(layout.buildDirectory.dir("spider-fixture-classes"))
    sourceCompatibility = "17"
    targetCompatibility = "17"
}
val packageSpiderFixture = tasks.register<Jar>("packageSpiderFixture") {
    dependsOn(compileSpiderFixture)
    from(compileSpiderFixture.flatMap { it.destinationDirectory })
    archiveFileName.set("classes.jar")
    destinationDirectory.set(layout.buildDirectory.dir("spider-fixture-input"))
}
val dexSpiderFixture = tasks.register<Exec>("dexSpiderFixture") {
    dependsOn(packageSpiderFixture)
    inputs.file(packageSpiderFixture.flatMap { it.archiveFile })
    outputs.file(layout.buildDirectory.file("spider-fixture/test-spider.jar"))
    doFirst {
        val output = layout.buildDirectory.file("spider-fixture/test-spider.jar").get().asFile
        output.parentFile.mkdirs()
        commandLine(File(android.sdkDirectory, "build-tools/${android.buildToolsVersion}/d8").path,
            "--lib", android.bootClasspath.first().path,
            "--classpath", layout.buildDirectory.dir("intermediates/javac/debug/compileDebugJavaWithJavac/classes").get().asFile.path,
            "--min-api", android.defaultConfig.minSdk.toString(),
            "--output", output.path, packageSpiderFixture.get().archiveFile.get().asFile.path)
    }
}
tasks.configureEach {
    if (name == "mergeDebugAndroidTestAssets") dependsOn(dexSpiderFixture)
}

flutter {
    source = "../.."
}

dependencies {
    // CatVod plugins reference these host APIs rather than bundling them.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.code.gson:gson:2.13.1")
    implementation("wang.harlon.quickjs:wrapper-android:3.2.3")
    implementation("wang.harlon.quickjs:wrapper-java:3.2.3")
    testImplementation("junit:junit:4.13.2")
}
