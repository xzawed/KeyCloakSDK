// 통합 커버리지 자가테스트의 kotlin 픽스처 — 실제 kotlin/build.gradle.kts 의 꼴(Kover 0.9.x · jvm-test-suite 의 integrationTest ·
// kover excludes.classes)이다. 데이터는 도구의 run kotlin 이 만든다(scripts/test/test-integration-coverage.sh 머리).
plugins {
    kotlin("jvm") version "2.4.21"
    id("org.jetbrains.kotlinx.kover") version "0.9.11"
}

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
}

@Suppress("UnstableApiUsage")
testing {
    suites {
        val integrationTest by registering(JvmTestSuite::class) {
            useJUnitJupiter("6.1.1")
            dependencies {
                implementation(project())
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            }
        }
    }
}

kover {
    currentProject {
        instrumentation {
            disabledForTestTasks.add("integrationTest")
        }
        sources {
            excludedSourceSets.add("integrationTest")
        }
    }
    reports {
        filters {
            excludes {
                classes(
                    "kc.auth.AuthClient*",
                    "kc.examples.*",
                )
            }
        }
    }
}
