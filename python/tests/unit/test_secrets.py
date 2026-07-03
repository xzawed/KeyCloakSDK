from keycloak_sdk._internal.secrets import mask
def test_mask():
    assert mask(None) == "***"
    assert mask("ab") == "***"
    assert mask("abcde") == "***"  # 5자 — 짧은 시크릿은 강화된 마스킹(<8) 대상
    assert mask("abcdefg") == "***"  # 7자 — 경계값 바로 아래
    assert mask("abcdefgh") == "abc***"  # 8자 — 경계값(>=8)에서 접두 마스킹
    assert mask("abcdef123") == "abc***"
