package kc.auth

import kotlinx.coroutines.delay

/** 통합 커버리지 픽스처 — kotlin 이 만드는 생성 이름 꼴을 고루 갖는다(경계 파일 — build.gradle.kts 의 `kc.auth.AuthClient*`). */
class AuthClient(private val base: String) {
    companion object {
        /** Companion 의 속성 — 바깥 클래스의 정적 초기화가 채운다(실릴 때 돈다). */
        val REALM: String = "kc".uppercase()

        /** 속성 초기화의 람다 — 그 속성의 것이다. */
        val UPPER: (String) -> String = { it.uppercase() }

        fun create(base: String): AuthClient = AuthClient(base)
    }

    fun names(users: List<String>): List<String> = users.map { mask(it) }

    /** 오버로드 — 람다(`token$lambda$N`)는 그것을 만든 오버로드에 붙는다. */
    fun token(user: String): String = describe { base + user }

    fun token(
        user: String,
        ttl: Int,
    ): String = describe { base + user + ttl }

    /** suspend — 이어받기 클래스(`AuthClient$fetch$1`)는 줄표가 없다. */
    suspend fun fetch(user: String): String {
        delay(1)
        return token(user)
    }

    /** `internal` — 이름 뒤에 모듈 접미가 붙는다(기본 인자 다리에도 — `mask$<모듈>$default`). */
    internal fun mask(value: String, stars: String = "***"): String = stars + value.length

    /** 기본 인자 — 다리 `label$default` 가 생긴다. */
    fun label(prefix: String = "kc"): String = prefix + base

    /** 익명 객체 — EnclosingMethod 로 sorted 에 접힌다. */
    fun sorted(items: List<String>): List<String> =
        items.sortedWith(
            object : Comparator<String> {
                override fun compare(
                    a: String,
                    b: String,
                ): Int = a.compareTo(b)
            },
        )

    /** 부르지 않는다(미실행). */
    fun unused(): String = base.repeat(2)

    private fun describe(s: () -> String): String = s()

    /** 인스턴스 속성 초기화의 람다 — 생성자가 만든다(부르지 않는다). */
    private val greet: () -> String = { "hi " + base }

    /** 초기화 블록의 람다 — 생성자가 만든다(부르지 않는다). */
    private val ready: () -> Boolean

    init {
        ready = { base.isNotEmpty() }
    }
}
