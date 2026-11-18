// 단위 미도달 장부 자가테스트의 kotlin 픽스처 — 실제 kotlin/build.gradle.kts 의 꼴(Kover 0.9.x · kover excludes.classes · 단위 test).
// 데이터는 도구의 `unit kotlin` 이 만든다(scripts/test/test-unit-unreached.sh 머리).
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
    testImplementation(kotlin("test"))
    testImplementation(platform("org.junit:junit-bom:6.1.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}

kover {
    reports {
        filters {
            excludes {
                classes(
                    "kc.auth.AuthClient*",
                )
            }
        }
    }
}
