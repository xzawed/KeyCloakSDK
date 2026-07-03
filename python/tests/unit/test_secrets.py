from keycloak_sdk._internal.secrets import mask
def test_mask():
    assert mask(None) == "***"
    assert mask("ab") == "***"
    assert mask("abcdef123") == "abc***"
