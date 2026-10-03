pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.application") version "9.0.1" apply false
    // 与主工程一致，用已缓存的 Kotlin Gradle 插件满足 AGP 的构建依赖。
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
