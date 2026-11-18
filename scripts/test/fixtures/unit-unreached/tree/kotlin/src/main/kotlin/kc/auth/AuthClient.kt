package kc.auth

/** 단위 미도달 장부 픽스처 — 경계 파일(build.gradle.kts 의 `kc.auth.AuthClient*`). 단위 구동은 src/test 의 DriveTest 다. */
class AuthClient(
    private val base: String,
) {
    /** 단위 구동이 다 닿는다 — 장부에 없다. */
    fun realm(): String = base

    /** 제 줄에 선 실패 갈래 — 구동은 빈 code 를 안 보낸다(놓친 줄 · 놓친 가지). */
    fun exchange(code: String): String {
        if (code.isBlank()) {
            throw IllegalStateException("blank code")
        }
        return code.uppercase()
    }

    /** 행복 경로가 도는 줄에 붙은 실패 갈래(elvis) — 줄은 돌고 가지 하나만 놓친다. */
    fun elvis(v: String?): String = v ?: throw IllegalArgumentException("none")

    /** 람다 안의 갈래 — 구동은 null 을 안 넘긴다. 그 가지는 람다 메서드의 것이고 장부의 키는 소스 함수 pick 이다. */
    fun pick(v: String?): String = later { if (v == null) "none" else v }

    /** 인라인 함수(require) 안의 실패 갈래 — 구동은 빈 user 를 안 보낸다. */
    fun token(user: String): String {
        require(user.isNotEmpty()) { "empty user" }
        return base + user
    }

    /** 구동이 부르지 않는다 — 줄 전부를 놓친다. */
    fun unused(): String = base.repeat(2)
}

fun <T> later(f: () -> T): T = f()
