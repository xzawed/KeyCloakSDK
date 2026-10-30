"""Runtime messages are English.

The docstrings that `help()` renders were translated per module; strings that reach a consumer at
runtime are the other half — Korean messages once reached `KeycloakConfigError`. Docstrings and
comments are out of scope here: comments are not values, and docstrings are not runtime messages.
"""

import ast
import re
from pathlib import Path

SRC = Path(__file__).resolve().parents[2] / "src" / "keycloak_sdk"
HANGUL = re.compile(f"[{chr(0xAC00)}-{chr(0xD7A3)}]")


def hangul_strings(name: str, text: str) -> list[str]:
    """`name:line` of every string constant with Hangul that is not a docstring."""
    tree = ast.parse(text, filename=name)
    docstrings: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            first = node.body[0] if node.body else None
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                docstrings.add(id(first.value))
    return [
        f"{name}:{node.lineno}"
        for node in ast.walk(tree)
        if isinstance(node, ast.Constant)
        and isinstance(node.value, str)
        and id(node) not in docstrings
        and HANGUL.search(node.value)
    ]


def test_detector_finds_messages_not_docstrings() -> None:
    assert hangul_strings("a.py", 'raise ValueError("실패")\n') == ["a.py:1"]
    assert hangul_strings("b.py", 'x = f"ok {y} 끝"\n') == ["b.py:1"]
    docstrings_and_comments = '"""실패"""\n# 실패\ndef f():\n    """실패"""\n    return "ok"\n'
    assert hangul_strings("c.py", docstrings_and_comments) == []


def test_no_hangul_in_runtime_strings() -> None:
    files = sorted(SRC.rglob("*.py"))
    assert len(files) > 10  # an empty walk would pass vacuously
    hits = [
        hit
        for f in files
        for hit in hangul_strings(f.relative_to(SRC).as_posix(), f.read_text(encoding="utf-8"))
    ]
    assert hits == []
