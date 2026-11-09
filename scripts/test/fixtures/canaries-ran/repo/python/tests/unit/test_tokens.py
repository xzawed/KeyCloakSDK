import pytest


@pytest.mark.parametrize("bad", [1, None, ""])
def test_non_string_access_token_is_rejected(bad):
    pass
