from keycloak_sdk._internal.secrets import mask


def test_mask_present_value_is_fully_opaque():
    # 접두 노출 없음 — 길이와 무관하게 존재하는 값은 항상 "***"
    assert mask("ab") == "***"
    assert mask("abcdefgh") == "***"  # 과거엔 "abc***" (접두 3글자 유출) — 제거됨
    assert mask("abcdef123") == "***"
    assert mask("eyJhbGciOiJSUzI1NiJ9.payload.sig") == "***"


def test_mask_absent_value_is_empty():
    # None/빈 값은 부재를 빈 문자열로 표시(존재하지 않는 시크릿을 "***"로 오도하지 않음)
    assert mask(None) == ""
    assert mask("") == ""
