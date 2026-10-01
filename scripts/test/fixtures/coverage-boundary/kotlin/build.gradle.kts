plugins {
    id("org.jetbrains.kotlinx.kover") version "0.9.0"
}

kover {
    currentProject {
        sources { excludedSourceSets.add("integrationTest") }
    }
    reports {
        filters {
            excludes {
                // "p.Config*" — 주석 속 패턴은 세지 않는다
                classes(
                    "p.AuthClient*",
                    "p.admin.*",
                )
            }
        }
    }
}
