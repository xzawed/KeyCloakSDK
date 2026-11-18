package kc.auth

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
    }
}
