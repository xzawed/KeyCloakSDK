package io.github.xzawed.keycloak

import org.junit.jupiter.api.io.TempDir
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

// W1 의 사슬 판독(`hpChainWhy`)을 고정한다 — 행렬의 손 목록에서 사슬을 쓰는 행은 콜드 캐시 근거 하나뿐이라, 도우미 호출
// 검사를 꺼도 지금 트리에서는 초록이었다(#1031 레그 W1d). 같은 모양의 작은 원본으로 네 갈래를 친다.
class HostilePathMatrixW1ChainTest {
    private fun source(
        dir: Path,
        text: String,
    ): Path = dir.resolve("S.kt").also { Files.writeString(it, text) }

    private fun why(
        file: Path,
        chain: List<String>,
    ): List<String> = hpChainWhy(file, "S.kt|t", hpFunctionBody(file, "t") ?: error("앵커 t 를 못 읽었다"), chain)

    @Test
    fun `a test that reaches the target through its helper passes`(
        @TempDir dir: Path,
    ) {
        val f =
            source(
                dir,
                """
                fun t() = runTest { run(1) }
                private fun run(x: Int): Int { validator.validate(x); return 0 }
                """.trimIndent(),
            )
        assertEquals(emptyList(), why(f, listOf("run", "validate")))
    }

    @Test
    fun `a test that no longer calls the helper is named`(
        @TempDir dir: Path,
    ) {
        val f =
            source(
                dir,
                """
                fun t() = runTest { validator.validate(1) }
                private fun run(x: Int): Int { validator.validate(x); return 0 }
                """.trimIndent(),
            )
        val got = why(f, listOf("run", "validate"))
        assertTrue(got.any { "도우미 run( 를 부르지 않는다" in it }, "도우미를 안 부르는 시험이 통과했다: $got")
    }

    @Test
    fun `a missing helper is named`(
        @TempDir dir: Path,
    ) {
        val f = source(dir, "fun t() = runTest { run(1) }")
        val got = why(f, listOf("run", "validate"))
        assertTrue(got.any { "도우미 run 가 없다" in it }, "없는 도우미가 통과했다: $got")
    }

    @Test
    fun `a helper that no longer calls the target is named`(
        @TempDir dir: Path,
    ) {
        val f =
            source(
                dir,
                """
                fun t() = runTest { run(1) }
                private fun run(x: Int): Int { return x }
                """.trimIndent(),
            )
        val got = why(f, listOf("run", "validate"))
        assertTrue(got.any { "앵커가 .validate( 를 부르지 않는다" in it }, "대상을 안 부르는 도우미가 통과했다: $got")
    }
}
