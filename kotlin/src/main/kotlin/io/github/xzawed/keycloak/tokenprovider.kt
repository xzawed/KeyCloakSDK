package io.github.xzawed.keycloak

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Clock
import java.time.Duration

// tokenprovider.kt — auth와 admin을 잇는 유일한 접착제(§4). AuthClient(Task 7)를 직접 알지 못하고
// `fetch: suspend () -> TokenSet` 공급자만 받는다 — admin은 전용 인스턴스를 주입받아
// 무캐시 AuthClient 직접주입을 피한다(Rust SDK 79ecf76 교훈 선반영).
public fun interface TokenProvider {
    public suspend fun accessToken(): String
}

public class ClientCredentialsTokenProvider(
    private val fetch: suspend () -> TokenSet,
    private val clock: Clock = Clock.systemUTC(),
    private val skew: Duration = Duration.ofSeconds(30),
) : TokenProvider {
    @Volatile
    private var cached: TokenSet? = null
    private val mutex = Mutex()

    override suspend fun accessToken(): String {
        cached?.let { if (!it.isExpired(clock, skew)) return it.accessToken }
        return mutex.withLock {
            cached?.let { if (!it.isExpired(clock, skew)) return@withLock it.accessToken }
            val fresh = fetch()
            cached = fresh
            fresh.accessToken
        }
    }
}
