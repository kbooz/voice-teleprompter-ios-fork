pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Suflyor"
include(":app")

// The tracker, script normalizers and importers shared with the iOS app (Kotlin Multiplatform, builds without the
// Android SDK). Gradle substitutes com.olerast.suflyor:core with this build.
includeBuild("core")
