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

    // ── 아래는 이름으로 못 접는 꼴이다(kotlin 2.4.21 실측) — 리더는 클래스 파일의 코드로 접는다 ──

    /** 람다 안의 람다 — 안쪽 이름은 `nested$lambda$0$0` 이다(만드는 것은 바깥 람다). */
    fun nested(): String = describe { describe { base } }

    /** 로컬 함수(`withLocal$inner`)와 그 안의 람다 — 부르는 메서드 · 만드는 메서드로 접는다. */
    fun withLocal(): String {
        fun inner(x: String): String = describe { x + base }
        return inner("l")
    }

    /** 로컬 클래스 — 이름에 숫자가 없다(`AuthClient$withLocalClass$Local`). 부르지 않는다. */
    fun withLocalClass(): Int {
        class Local(
            val n: Int,
        ) {
            fun twice(): Int = n * 2
        }
        return Local(3).twice()
    }

    /** `@JvmName` 오버로드 — 두 람다는 `join$lambda$N` 이지만 둘째를 만드는 것은 `joinInts` 다. 구동은 joinInts 만 부른다. */
    fun join(xs: List<String>): String = describe { xs.joinToString() }

    @JvmName("joinInts")
    fun join(xs: List<Int>): String = describe { xs.sum().toString() }
}

/** 기본 인자 생성자(`<init>(…, int, DefaultConstructorMarker)`) · 그 기본값의 람다(`_init_$lambda$N` — 그 생성자가 만든다) ·
 *  컴패니언 init 의 람다(같은 이름 꼴 — 정적 초기화가 만든다). 구동은 컴패니언만 부른다(생성자는 안 돈다). */
class AuthClientStatus(
    private val code: Int,
    private val hook: () -> String = { "ok" },
) {
    companion object {
        init {
            describeStatic { "boot" }
        }

        fun ok(): Int = 200
    }
}

/** object 의 `@JvmStatic` 다리는 받는 쪽이 없다 — 첫 매개변수가 그 object 타입이어도 매개변수다. 구동은 다리만 부른다. */
object AuthClientDefaults {
    @JvmStatic
    fun pick(
        o: AuthClientDefaults?,
        n: Int = 0,
    ): Int = n + (if (o == null) 0 else 1)

    @JvmStatic
    fun pick(n: Int): Int = n
}

/** open suspend fun — 몸통은 `load$suspendImpl` 이다(JaCoCo 는 그것만 싣는다). */
open class AuthClientLoader {
    open suspend fun load(n: Int): Int {
        delay(1)
        return n
    }
}

fun describeStatic(s: () -> String): String = s()

/** 값 클래스 매개변수의 함수 — JVM 이름에 `-` 가 든다(`byId-<해시>` · 그 람다는 `byId_<해시>$lambda$0`). 값 클래스는 경계 밖(Config.kt). */
fun byId(id: ClientId): String = describeStatic { id.v }

/** 인터페이스의 기본 메서드와 기본 인자 — 다리 `ping$default` 가 인터페이스와 `DefaultImpls` 둘에 있다(뒤는 앞을 부른다). */
interface AuthClientApi {
    fun ping(n: Int = 1): Int = n
}

class AuthClientApiImpl : AuthClientApi

/** 안 실리는 object — 정적 초기화와 그것이 만드는 람다는 미실행 목록에 들지 않는다. */
object AuthClientIdle {
    private val f: () -> Int = { 1 }
}
