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


def _names(node: ast.AST) -> list[str]:
    """Identifiers a node carries — names reach a consumer as `__name__`, attributes, tracebacks."""
    if isinstance(node, ast.Name):
        return [node.id]
    if isinstance(node, ast.Attribute):
        return [node.attr]
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        return [node.name]
    if isinstance(node, ast.arg):
        return [node.arg]
    if isinstance(node, ast.keyword):
        return [node.arg] if node.arg else []
    if isinstance(node, ast.alias):
        return [node.name, node.asname or ""]
    return []


def hangul_values(name: str, text: str) -> list[str]:
    """`name:line` of every non-docstring string constant or identifier that contains Hangul."""
    tree = ast.parse(text, filename=name)
    docstrings: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            first = node.body[0] if node.body else None
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                docstrings.add(id(first.value))
    hits = []
    for node in ast.walk(tree):
        texts = _names(node)
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            texts = [] if id(node) in docstrings else [node.value]
        if any(HANGUL.search(t) for t in texts):
            hits.append(f"{name}:{getattr(node, 'lineno', 0)}")
    return hits


def test_detector_finds_messages_and_names_not_docstrings() -> None:
    assert hangul_values("a.py", 'raise ValueError("실패")\n') == ["a.py:1"]
    assert hangul_values("b.py", 'x = f"ok {y} 끝"\n') == ["b.py:1"]
    docstrings_and_comments = '"""실패"""\n# 실패\ndef f():\n    """실패"""\n    return "ok"\n'
    assert hangul_values("c.py", docstrings_and_comments) == []
    # A class name reaches a consumer in `repr`, `__name__` and every traceback.
    assert hangul_values("d.py", "class 오류(Exception):\n    pass\n") == ["d.py:1"]


def test_no_hangul_in_runtime_strings() -> None:
    files = sorted(SRC.rglob("*.py"))
    assert len(files) > 10  # an empty walk would pass vacuously
    hits = [
        hit
        for f in files
        for hit in hangul_values(f.relative_to(SRC).as_posix(), f.read_text(encoding="utf-8"))
    ]
    assert hits == []
