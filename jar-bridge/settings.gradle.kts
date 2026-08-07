pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        // 国内网络兜底；官方仓库始终优先，校验和由 dependency verification 固定。
        maven("https://maven.aliyun.com/repository/gradle-plugin")
        maven("https://maven.aliyun.com/repository/public")
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        mavenCentral()
        maven("https://maven.aliyun.com/repository/public")
    }
}

rootProject.name = "jar-bridge"
