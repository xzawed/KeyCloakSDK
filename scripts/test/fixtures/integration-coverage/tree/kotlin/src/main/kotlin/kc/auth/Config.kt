package kc.auth

/** 경계 밖(kover excludes 에 없다) — 리포트에 안 든다. */
object Config {
    fun realm(): String = "kc"
}

/** 값 클래스 — AuthClient.kt 의 `byId` 가 받는다(그 함수의 JVM 이름이 맹글된다). 경계 패턴(`AuthClient*`) 밖의 이름이다. */
@JvmInline
value class ClientId(
    val v: String,
)
