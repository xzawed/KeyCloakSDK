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

/** 실제 레인의 adminCall 꼴(제네릭 suspend 함수) — 이 사본에는 멈출 자리가 없어 늘 멈추지 않고 돌아온다. */
suspend fun <T> adminCall(block: () -> T): T = block()

/**
 * 꼬리 호출(등록부 kotlin-tail-call-return-line-flips) — Unit 을 돌려주는 suspend 함수의 마지막 문장이 Unit 을 돌려주는 suspend 호출이면
 * kotlinc 는 그것을 꼬리 호출로 내고, 닫는 중괄호 줄에는 마지막 areturn 하나만 남는다: 호출이 멈추지 않고 돌아왔을 때만 돈다(호출이
 * 값을 돌려주면 상태 기계다 — 실측). 구동은 멈추지 않는 adminCall 로 불러 그 줄까지 돈 데이터다(멈춘 실행의 데이터는 자가테스트가 그
 * 자리만 바꿔 만든다).
 */
class AuthClientTail(
    private val names: MutableList<String>,
) {
    suspend fun update(name: String) {
        names.add(name)
        adminCall { names.clear() }
    }
}
