package kc.auth

/** 경계 밖 파일 — 단위 게이트(Kover)가 재는 쪽이다. 장부가 이 파일을 가리키면 그 항목은 경계 밖이다. */
class Config(
    val realm: String,
) {
    fun valid(): Boolean = realm.isNotEmpty()
}
