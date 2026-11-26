import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    kotlin("multiplatform") version "2.3.20"
}

group = "com.olerast.suflyor"
version = "1.0"

kotlin {
    // The Android app uses JVM 17 bytecode. No Gradle toolchain: whatever JDK runs Gradle compiles it.
    jvm {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    // Static XCFramework "SuflyorCore" for the iOS app: ./gradlew -p core assembleSuflyorCoreReleaseXCFramework (on a Mac).
    val xcframework = XCFramework("SuflyorCore")
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "SuflyorCore"
            isStatic = true
            xcframework.add(this)
        }
    }

    sourceSets {
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
