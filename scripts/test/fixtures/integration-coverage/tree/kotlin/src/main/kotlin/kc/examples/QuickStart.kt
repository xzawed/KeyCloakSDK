package kc.examples

import kc.auth.AuthClient

/** 예제 — 통합 테스트가 안 부른다(파일 파사드 `QuickStartKt`). */
fun main() {
    println(AuthClient.create(env("KC_BASE", "http://localhost")).token("u"))
}

internal fun env(
    name: String,
    fallback: String,
): String = System.getenv(name) ?: fallback
