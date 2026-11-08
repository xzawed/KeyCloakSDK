package kc.it

import kc.auth.AuthClient
import kc.auth.AuthClientApiImpl
import kc.auth.AuthClientBag
import kc.auth.AuthClientCfg
import kc.auth.AuthClientCross
import kc.auth.AuthClientDefaults
import kc.auth.AuthClientError
import kc.auth.AuthClientHooks
import kc.auth.AuthClientInline
import kc.auth.AuthClientInlines
import kc.auth.AuthClientLoader
import kc.auth.AuthClientLoaders
import kc.auth.AuthClientLocals
import kc.auth.AuthClientMixed
import kc.auth.AuthClientNest
import kc.auth.AuthClientOvd
import kc.auth.AuthClientProps
import kc.auth.AuthClientRefs
import kc.auth.AuthClientRelay
import kc.auth.AuthClientShapes
import kc.auth.AuthClientStatic
import kc.auth.AuthClientStatus
import kc.auth.AuthClientSusp
import kc.auth.AuthClientTokens
import kc.auth.AuthClientVars
import kc.auth.ClientId
import kc.auth.Config
import kc.auth.byId
import kc.auth.makeOps
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
        check(byId(ClientId("i")) == "i")
        check(AuthClientApiImpl().ping() == 1)
        val l = AuthClientLocals()
        check(l.withDefault() == 10)
        check(l.withMutual(2) == 0)
        check(l.withCallback(2) == 0)
        check(AuthClientError("m", RuntimeException()).message == "m")
        check(AuthClientMixed(1).toString().isNotEmpty())
        check(AuthClientStatic.stat(1) == 2)
        check(AuthClientBag().size() == 0)
        check(runBlocking { AuthClientHooks.onStart() } == 1)
        check(runBlocking { AuthClientHooks.token.token() } == "t")
        check(AuthClientRefs().withLocalRef() == 2)
        check(AuthClientInline().useWrap() == 3)
        check(runBlocking { AuthClientLoaders().load(1) } == 1)
        check(AuthClientSusp("x").toString().isNotEmpty())
        check(AuthClientTokens.Parser().parse("ab") == 2)
        check(AuthClientProps.p == 7)
        val sh = AuthClientShapes()
        check(sh.x == 4)
        check(sh.useOp() == 2)
        check(AuthClientNest.Inner.f(1) == 2)
        check(AuthClientRelay.Target.f(1) == 2)
        check(makeOps() == 2)
        AuthClientVars.v = 3
        check(AuthClientVars.v == 3)
        AuthClientVars.isOn = true
        check(AuthClientVars.isOn)
        AuthClientVars.w = 4
        check(AuthClientVars.w == 4)
        check(AuthClientVars.over(1) == 3)
        check(AuthClientInlines().useInlines() == 8)
        check(runBlocking { AuthClientInlines().useS() } == 2)
        check(AuthClientOvd().pick() == 3)
        check(AuthClientCfg("x").parent?.name == "root")
        check(AuthClientCross().useLocal() == 6)
    }
}
