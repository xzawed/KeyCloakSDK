"""Rendered docs are English — what `help()` and IDE hovers show for the public surface.

The translation was measured on pydoc's plain-text rendering of the public modules (registry
`korean-api-docs-in-published-packages`). This renders the same set, so a Korean docstring cannot
come back — nor a `#` comment block above an undocumented public def, which pydoc shows in its
place (`inspect.getcomments`).
"""

import importlib
import pkgutil
import pydoc
import re
import types

import keycloak_sdk

# The repository's one definition of "public module" — imported, not copied.
from .test_hostile_path_matrix import _public_module

HANGUL = re.compile(f"[{chr(0xAC00)}-{chr(0xD7A3)}]")


def _public_modules() -> list[str]:
    walked = pkgutil.walk_packages(keycloak_sdk.__path__, "keycloak_sdk.")
    return [n for n in ["keycloak_sdk", *(m.name for m in walked)] if _public_module(n)]


def _hangul_lines(module: types.ModuleType) -> list[str]:
    text = pydoc.render_doc(module, renderer=pydoc.plaintext)
    path = getattr(module, "__file__", None) or ""
    # pydoc prints the module's file path — a checkout under a Hangul directory name is not a doc.
    return [
        line.strip()
        for line in text.splitlines()
        if HANGUL.search(line) and not (path and path in line)
    ]


def test_renderer_control() -> None:
    assert len(_hangul_lines(types.ModuleType("probe", "모듈 설명"))) == 1
    assert _hangul_lines(types.ModuleType("probe", "Module docs")) == []


def test_public_docs_have_no_hangul() -> None:
    names = _public_modules()
    assert len(names) >= 15  # an empty walk would pass vacuously
    hits = [f"{n}: {line}" for n in names for line in _hangul_lines(importlib.import_module(n))]
    assert hits == []
