// Standalone build: no Android Gradle Plugin and no Google Maven, so it builds and tests anywhere with a JDK
// (./gradlew -p core jvmTest). The Android app consumes it through includeBuild("core") in the root settings.
pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

rootProject.name = "core"
