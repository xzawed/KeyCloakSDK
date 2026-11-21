package kc.auth

import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** 단위 구동 — 경계의 일부만 닿는다(빈 code · null · 빈 user 를 안 보내고 unused 를 안 부른다). */
class DriveTest {
    @Test
    fun drive() {
        val a = AuthClient("kc")
        assertEquals("kc", a.realm())
        assertEquals("ABC", a.exchange("abc"))
        assertEquals("x", a.elvis("x"))
        assertEquals("x", a.pick("x"))
        assertEquals("kcu", a.token("u"))
        assertTrue(Config("demo").valid())
        // 꼬리 호출 — adminCall 이 멈추지 않고 돌아와 닫는 중괄호 줄(마지막 areturn)까지 돈다.
        val names = mutableListOf("x")
        var done: Result<Unit>? = null
        suspend { AuthClientTail(names).update("ab") }.startCoroutine(Continuation(EmptyCoroutineContext) { done = it })
        assertEquals(Result.success(Unit), done)
        assertTrue(names.isEmpty())
    }
}
