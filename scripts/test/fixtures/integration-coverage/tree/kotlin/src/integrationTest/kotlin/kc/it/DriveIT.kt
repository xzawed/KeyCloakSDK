package kc.it

import kc.auth.AuthClient
import kc.auth.AuthClientDefaults
import kc.auth.AuthClientLoader
import kc.auth.AuthClientStatus
import kc.auth.Config
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Test

/** 픽스처의 통합 테스트 — 경계를 일부만 부른다. `KC_FIXTURE_ZERO=1` 이면 경계 클래스를 싣기만 한다(0 실행의 데이터). */
class DriveIT {
    @Test
    fun drive() {
        if (System.getenv("KC_FIXTURE_ZERO") == "1") {
            check(Config.realm() == "kc")
            Class.forName("kc.auth.AuthClient")
            return
        }
        val c = AuthClient.create("b")
        check(c.token("u").isNotEmpty())
        check(c.names(listOf("a")).size == 1)
        check(runBlocking { c.fetch("u") }.isNotEmpty())
        check(c.label().isNotEmpty())
        check(c.sorted(listOf("b", "a")) == listOf("a", "b"))
        check(AuthClient.UPPER("x") == "X")
        check(c.nested() == "b")
        check(c.withLocal() == "lb")
        check(c.join(listOf(1, 2)) == "3")
        check(AuthClientStatus.ok() == 200)
        check(AuthClientDefaults.pick(null) == 0)
        check(runBlocking { AuthClientLoader().load(1) } == 1)
    }
}
