package io.github.xzawed.keycloak

// masking.kt — internal, 접두 노출 없음
internal fun mask(v: CharArray?) = if (v == null || v.isEmpty()) "" else "***"

internal fun mask(v: String?) = if (v.isNullOrEmpty()) "" else "***"
