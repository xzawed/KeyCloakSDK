package io.x

class P {
    @ParameterizedTest
    @ValueSource(strings = ["a"])
    fun `r2 parameterized`(s: String) {}
}
