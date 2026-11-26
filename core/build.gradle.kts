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

    // The parity tests compare Unicode tables with the JDK that runs them, and only match JDK 21 (Unicode 15).
    // So run jvmTest on JDK 21 via a toolchain launcher; this does not change the Gradle JDK or the JVM 17 bytecode.
    tasks.withType<Test>().configureEach {
        javaLauncher.set(
            javaToolchains.launcherFor { languageVersion.set(JavaLanguageVersion.of(21)) }
        )
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
