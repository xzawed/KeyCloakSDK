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

// ── 아래는 독립 레그 2 가 컴파일해 보인 꼴이다 — 접기가 자기에게 돌아오거나, EnclosingMethod 가 틀리거나, 이름이 같은 남을 부른다 ──

fun <T> later(f: () -> T): T = f()

/** 접기가 자기에게 돌아오는 로컬 함수 — 기본 인자(`withDefault$inner` ↔ `$default`) · 서로 부르기 · 자기 람다가 다시 부르기. */
class AuthClientLocals {
    fun withDefault(): Int {
        fun inner(x: Int = 5): Int = x * 2
        return inner()
    }

    fun withMutual(n: Int): Int {
        fun a(k: Int): Int {
            fun b(j: Int): Int = if (j <= 0) 0 else a(j - 1)
            return b(k)
        }
        return a(n)
    }

    fun withCallback(n: Int): Int {
        fun r(k: Int): Int = if (k <= 0) 0 else later { r(k - 1) }
        return r(n)
    }
}

/** 본 생성자 없는 클래스의 속성 초기화 객체 — 생성자마다 그 코드가 들어 둘이 함께 만든다(어느 하나의 실행 근거가 아니다).
 *  구동은 둘째 생성자만 부른다. */
class AuthClientError : RuntimeException {
    private val hook: Runnable =
        object : Runnable {
            override fun run() {}
        }

    constructor(m: String) : super(m)
    constructor(m: String, c: Throwable) : super(m, c)
}

/** 첫 생성자가 둘째에 맡긴다 — 속성 초기화 객체의 EnclosingMethod 는 첫 생성자를 대지만 만드는 것은 둘째다. 구동은 둘째만. */
class AuthClientMixed {
    private val r: Runnable =
        object : Runnable {
            override fun run() {}
        }

    constructor(s: String) : this(s.length)
    constructor(x: Int) {
        check(x >= 0)
    }
}

/** 컴패니언 `@JvmStatic` — 바깥 정적 다리는 컴패니언의 것을 부를 뿐이다(kotlin 호출은 컴패니언으로 가 다리는 안 돈다). */
class AuthClientStatic private constructor() {
    companion object {
        @JvmStatic
        fun stat(x: Int): Int = x + 1
    }
}

/** 기본값이 다른 클래스를 만드는 기본 인자 생성자(`ArrayList.<init>` 도 부른다) · 이름이 같은 남의 메서드(`List.size`)를 부르는 다리. */
class AuthClientBag(
    private val xs: MutableList<String> = ArrayList(),
) {
    fun size(
        ys: List<Int> = emptyList(),
        n: Int = ys.size,
    ): Int = n + xs.size
}

/** 정적 초기화의 suspend 람다(그 클래스의 `create()` 가 자기를 다시 `new` 한다) · 싱글턴 fun interface 변환(INSTANCE 로만 쓰인다). */
object AuthClientHooks {
    val onStart: suspend () -> Int = { 1 }
    val token: AuthClientTokenSource = AuthClientTokenSource { "t" }
}

fun interface AuthClientTokenSource {
    suspend fun token(): String
}

fun takeInt(f: (Int) -> Int): Int = f(1)

/** 함수 참조로 쓰인 로컬 함수(합성 접근자 `access$withLocalRef$twice` 를 거쳐 불린다) · 초기화 블록의 로컬 함수(`_init_$warm`). */
class AuthClientRefs {
    init {
        fun warm(): Int = 1
        check(warm() == 1)
    }

    fun withLocalRef(): Int {
        fun twice(x: Int): Int = x * 2
        return takeInt(::twice)
    }
}

/** 인라인 함수 안의 람다 클래스(`AuthClientInline$wrap$1`) — 인라인된 호출부(useWrap)에서도 `new` 된다(자리가 갈린다): EnclosingMethod
 *  (어휘)로 그 인라인 함수에 접는다. */
class AuthClientInline {
    inline fun wrap(noinline f: () -> Int): Int = later { f() + 1 }

    fun useWrap(): Int = wrap { 2 }
}

/** 오버로드된 open suspend fun — 몸통 `load$suspendImpl` 둘이 저마다 그 오버로드다(JaCoCo 는 fun 을 안 싣는다). 구동은 load(Int) 만. */
open class AuthClientLoaders {
    open suspend fun load(n: Int): Int {
        delay(1)
        return n
    }

    open suspend fun load(s: String): Int {
        delay(1)
        return s.length
    }
}

/** 본 생성자 없는 클래스의 suspend 람다 속성 — 생성자 둘이 함께 만들고, 그 람다 클래스의 `create()` 도 제 클래스를 만든다(자기 안의
 *  자리는 뺀다). 구동은 둘째 생성자만. */
class AuthClientSusp {
    private val h: suspend () -> Int = { 1 }

    constructor(n: Int) {
        check(n >= 0)
    }

    constructor(s: String) {
        check(s.isNotEmpty())
    }
}

// ── 아래는 독립 레그 3 이 컴파일해 보인 꼴이다 ──

/** 진짜 `@JvmStatic` 메서드가 중첩 클래스의 같은 이름을 부른다 — 다리가 아니다(부르는 쪽 메서드에 표지가 없다). 구동은 Parser 만. */
object AuthClientTokens {
    class Parser {
        fun parse(s: String): Int = s.length
    }

    @JvmStatic
    fun parse(s: String): Int = Parser().parse(s)
}

/** 컴패니언 `@JvmStatic val` — 바깥 정적 게터의 표지는 컴패니언의 `getP$annotations` 에 있다. 구동은 컴패니언으로 읽는다(다리는 안
 *  돈다). */
class AuthClientProps private constructor() {
    companion object {
        @JvmStatic
        val p: Int get() = later { 7 }
    }
}

/** 게터 안의 로컬 함수(`_get_x_$loc` — 접두가 JVM 이름 getX 와 다르다) · Java SAM 참조의 어댑터(`useOp$loc$0` — invokedynamic 의
 *  구현인 private static 메서드). */
class AuthClientShapes {
    val x: Int
        get() {
            fun loc(): Int = 4
            return loc()
        }

    fun useOp(): Int {
        fun loc(v: Int): Int = v + 1
        return applyOp(::loc)
    }
}

fun applyOp(op: java.util.function.IntUnaryOperator): Int = op.applyAsInt(1)

// ── 아래는 `@JvmStatic` 다리 판별의 조건마다 하나씩이다 — 진짜 `@JvmStatic` 이 표지 있는 같은 이름을 부르지만 다리가 아니다 ──

/** 중첩 object 의 `@JvmStatic` 을 부른다 — 받는 쪽이 정적 메서드다(컴패니언의 다리가 부르는 것은 인스턴스 메서드다). 구동은 Inner 만. */
object AuthClientNest {
    object Inner {
        @JvmStatic
        fun f(x: Int): Int = x + 1
    }

    @JvmStatic
    fun f(x: Int): Int = Inner.f(x)
}

/** 중첩 클래스 컴패니언의 `@JvmStatic` 을 부른다 — 받는 쪽은 표지 있는 인스턴스 메서드지만 바로 아래 클래스가 아니다
 *  (`AuthClientRelay$Target$Companion` — 그 컴패니언의 다리는 `Target` 에 있다). 구동은 Target 만. */
object AuthClientRelay {
    class Target private constructor() {
        companion object {
            @JvmStatic
            fun f(x: Int): Int = x * 2
        }
    }

    @JvmStatic
    fun f(x: Int): Int = Target.f(x)
}

// ── 아래는 Java SAM 참조의 구현 판별이다 — 최상위 함수의 참조를 만들기만 하고 부르지 않는다 ──

private fun privTwice(x: Int): Int = x * 2

fun pubTwice(x: Int): Int = x * 3

fun keepOp(op: java.util.function.IntUnaryOperator): java.util.function.IntUnaryOperator = op

/** 참조된 함수(private 이면 private static)는 안 돌았다 — invokedynamic 의 구현이어도 그 함수다. 구동은 makeOps 만. */
fun makeOps(): Int {
    keepOp(::privTwice)
    keepOp(::pubTwice)
    return 2
}

/** 컴패니언 `@JvmStatic var` — 표지는 게터 이름의 `$annotations`(`getV$annotations` · `isOn$annotations`)에만 있어 세터 다리는 게터로
 *  가른다 · 세터만 `@set:JvmStatic`(표지는 세터에) · `@JvmOverloads`(만든 오버로드에도 표지). 구동은 컴패니언으로만(다리는 안 돈다). */
class AuthClientVars private constructor() {
    companion object {
        @JvmStatic
        var v: Int = 0

        @JvmStatic
        var isOn: Boolean = false

        var w: Int = 0
            @JvmStatic set

        @JvmStatic
        @JvmOverloads
        fun over(a: Int, b: Int = 2): Int = a + b
    }
}
