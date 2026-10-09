#!/usr/bin/env sh
# `check-known-gaps.mjs` 자가테스트 — HostilePathMatrix 의 알려진 틈(KNOWN_GAPS) ↔ 등록부 열린 항목.
#
# ⚠️ **픽스처만 쓴다 — 실제 트리의 행렬 파일도 등록부도 읽지 않는다.** 이 파일은 required 체크
# `doc-facts` 안에서 돈다. 판정이 가드 코드와 여기서 만든 임시 저장소에만 달려 있어서, 언어 CI 의
# 결과·산출물·네트워크 어느 것도 이 체크를 빨갛게 하지 못한다. 실제 트리 대조는 비-required 잡
# `known-gaps-join` 이 한다(`coverage-boundary` 와 같은 배치 — 아홉 언어 문법을 읽는 파서의 첫 도입
# 오탐이 required 에 있으면 모든 PR 이 멈춘다).
#
# 무게는 「통과한다」가 아니라 아래 셋이다.
#   (a) 양성 — 아홉 문법 각자의 문자열 표기로 적힌 id 를 찾고(열림 → 0 · 닫힘 → 1), 계산형 목록
#       (역사적 java·kotlin·python 모양)과 php 의 id 키 묶음도 찾는다.
#   (b) 음성 — 주석·다른 문자열 안의 `"<id>: …"` 는 참조가 아니다(기본 픽스처가 아홉 파일 전부에
#       **닫힌** id 를 주석·중첩 문자열로 심어 둔다 — 걸러지지 않으면 기본 픽스처가 1 로 빨개진다).
#   (c) 공허 — 아무것도 못 찾은 파서는 통과가 아니라 실패다: 비지 않은 선언에서 id 0 · 선언 없음 ·
#       행렬 없음 · 언어 0 · 등록부 항목 0. 언어 집합은 **트리에서 파생**하므로 열 번째 언어가 행렬
#       없이 들어오면 실패해야 한다(상수 목록이면 조용히 통과한다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-known-gaps.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

put() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

# ── 등록부 ────────────────────────────────────────────────────────────────────────────
# 실제 등록부 문법 그대로: 최상위 `- [ ] \`id\`` 가 열림, `- [x] \`id\`` 가 닫힘. 하위 불릿의 언급과
# 들여쓴 체크박스는 항목이 아니다. 대문자 첫 마디(`H1-…`)와 점(`…-0.44-…`)은 실제 id 모양이다.
registry() {
  put "$1/docs/superpowers/plans/remaining-work.md" <<'EOF'
# 잔여작업 등록부(픽스처)

## A. 픽스처 — 6건 (열림 3)

- [ ] `open-id-one` **[H/M]** 열린 항목
- [ ] `H9-open-upper-segment` **[L/S]** 첫 마디만 대문자인 열린 항목
- [ ] `php-thing-0.44-open` **[L/S]** 점이 든 열린 항목
- [x] `closed-id-one` **[M/S]** 닫힌 항목
  - 하위 서술이 `phantom-in-prose` 를 말하지만 항목이 아니다
  - [ ] `indented-not-an-item` 들여쓴 체크박스는 등록부 항목이 아니다
- [x] `closed-id-two` **[M/S]** 닫힌 항목 둘째
EOF
}

# ── 아홉 문법의 행렬 파일 — 머리 + 선언(인자) + 꼬리 ─────────────────────────────────────
# 머리·꼬리는 실제 행렬 파일에서 가져온 까다로운 모양을 담는다: URL 의 `//`, 문자 리터럴 `'"'`,
# 보간 구멍 안의 따옴표, 원시·텍스트 블록 문자열, 정규식 리터럴 속 따옴표·`#`, 중첩 블록 주석.
# 그리고 **닫힌 id 를 주석과 중첩 문자열 안에** 둔다(음성 대조군).
w_go() {
  { cat <<'EOF'
package p

import "fmt"

// 값은 `등록부 id: 이유` 다 — 예: "closed-id-one: 주석 속 예시는 참조가 아니다"
/* 블록 주석도: "closed-id-one: 이것도" */
EOF
    printf '%s\n' "$2"
    cat <<'EOF'

var raw = `raw "closed-id-one: 문자열 안의 따옴표는 리터럴이 아니다"
두 줄`

func hp() {
	u := "https://idp.example/realms/r" // URL 의 // 는 주석이 아니다
	r := '"'
	if _, known := hpKnownGaps[u]; known {
		fmt.Println(r, raw)
	}
	for key, reason := range hpKnownGaps {
		fmt.Printf("hpKnownGaps[%s]: 낡았다(%s)\n", key, reason)
	}
	// 실제 행렬 일곱이 가진 줄 — `W1` 은 등록부 id 가 아니다(문법이 한 마디 토큰을 받으면 거짓 참조가 된다).
	fmt.Println("W1: 저장소 밖(모듈 캐시)에서 돌아 보안 기본값 가드 대조는 건너뛴다")
}
EOF
  } | put "$1/lang-go/hostile_path_matrix_test.go"
}

w_java() {
  { cat <<'EOF'
package p;

import java.util.Map;

/**
 * 값은 {@code 등록부 id: 이유} — 예 "closed-id-one: 주석".
 */
class HostilePathMatrixTest {
  static final Map<String, String> NONCE_DROP_EXEMPT = Map.of(
      "AuthClient.exchangeCode(String,URI,String)", "무-nonce 흐름 — https://x.example/cb 도 주석이 아니다");

  // "closed-id-one: 줄 주석"
EOF
    printf '%s\n' "$2"
    cat <<'EOF'

  static String text = """
      "closed-id-one: 텍스트 블록 안"
      """;
  static char q = '"';

  void run(String key) {
    if (KNOWN_GAPS.containsKey(key)) System.out.println(q + text);
    KNOWN_GAPS.forEach((k, why) -> System.out.println("KNOWN_GAPS[" + k + "]: " + why));
  }
}
EOF
  } | put "$1/lang-java/src/test/java/p/HostilePathMatrixTest.java"
}

w_kt() {
  { cat <<'EOF'
package p

// 값은 `등록부 id: 한 줄 이유` — "closed-id-one: 주석"
/* 중첩 /* 주석 */ 도 "closed-id-one: 중첩 블록 주석 안" */
private val HP_NONCE_DROP_EXEMPT: Map<String, String> = emptyMap()

EOF
    printf '%s\n' "$2"
    cat <<'EOF'

private const val HP_URL = "https://app.example/cb"

internal class HostilePathMatrixTest {
    fun `known gaps are read, not written`() {
        val n = mapOf("m:rej" to 1)
        val line = "측정 ${(n["m:rej"] ?: 0)} · ${HP_URL}"
        val raw = """raw ${n["m:rej"]} "closed-id-one: 원시 문자열 안" """
        val c = '"'
        for ((key, reason) in HP_KNOWN_GAPS) println("HP_KNOWN_GAPS[$key]: $reason $line $raw $c")
        if ("x" in HP_KNOWN_GAPS) println(HP_NONCE_DROP_EXEMPT)
    }
}
EOF
  } | put "$1/lang-kotlin/src/test/kotlin/p/HostilePathMatrixTest.kt"
}

w_ts() {
  { cat <<'EOF'
import { describe, it } from 'vitest'

// 값은 `<등록부 id>: 한 줄 이유` — "closed-id-one: 주석"
/* "closed-id-one: 블록" */
const NONCE_DROP_EXEMPT: Readonly<Record<string, string>> = {}

EOF
    printf '%s\n' "$2"
    cat <<'EOF'

const URL_ARG = 'https://app.example/cb'
const strip = (s: string) => s.replace(/^['"]|['"]$/g, '').replace(/\/realms\/r\d+(?=\/|$)/, '/realms/r') // 정규식
const tpl = `${URL_ARG}/token ${`중첩 "closed-id-one: 템플릿 안"`}`

describe('m', () => {
  it('reads', () => {
    const fails: string[] = []
    for (const [key, reason] of Object.entries(KNOWN_GAPS)) {
      fails.push(`KNOWN_GAPS[${key}]: 낡았다(${reason}) ${strip(tpl)}`)
    }
    if ('x' in KNOWN_GAPS) fails.push(String(NONCE_DROP_EXEMPT))
  })
})
EOF
  } | put "$1/lang-node/test/unit/hostile-path-matrix.test.ts"
}

w_php() {
  { cat <<'EOF'
<?php

declare(strict_types=1);

namespace P;

// 값은 `등록부 id => [이유, 축, 행 목록, 변형 목록]` — 'closed-id-one' => 는 주석이다
# 'closed-id-one' => ['reason' => '샵 주석']
/* "closed-id-one: 블록" */
final class HostilePathMatrixTest
{
    private const NONCE_DROP_EXEMPT = [];

EOF
    printf '%s\n' "$2"
    cat <<'EOF'

    #[\PHPUnit\Framework\Attributes\Test]
    public function testRun(): void
    {
        $url = 'http://127.0.0.1:' . 8080 . '/realms/r'; // URL
        $id = 'x';
        $msg = "$id: {$url} 'closed-id-one: 큰따옴표 안의 작은따옴표'";
        foreach (self::knownGaps() as $key => $reason) {
            echo "KNOWN_GAP_GROUPS 의 칸 $key: $reason $msg";
        }
    }

    /** @return array<string, string> */
    private static function knownGaps(): array
    {
        $out = [];
        foreach (self::KNOWN_GAP_GROUPS as $id => $g) {
            $out["W3{$g['axis']} x/v"] = "$id: {$g['reason']}";
        }

        return $out;
    }
}
EOF
  } | put "$1/lang-php/tests/Unit/HostilePathMatrixTest.php"
}

w_py() {
  { cat <<'EOF'
"""모듈 독스트링 — 값은 `등록부 id: 이유`.

"closed-id-one: 독스트링 안" 은 참조가 아니다(독스트링 내용의 시작이 아니다).
"""

from __future__ import annotations

#: W3b 면제 — "closed-id-one: 주석"
_NONCE_DROP_EXEMPT: dict[str, str] = {}

EOF
    printf '%s\n' "$2"
    cat <<'EOF'

_URL = "http://127.0.0.1:8080/realms/r"  # URL 뒤의 진짜 주석


def test_reads() -> None:
    n = {"m:rej": 1}
    line = f"측정 {n['m:rej']} · {_URL} # 이건 주석이 아니다"
    fails = [f"_KNOWN_GAPS[{k}]: 낡았다({reason})" for k, reason in sorted(_KNOWN_GAPS.items())]
    assert not fails, line
    assert "x" not in _KNOWN_GAPS
    assert not (set() & _KNOWN_GAPS.keys())  # `&` 는 python 에서 읽기다 — 쓰기로 읽으면 빈 목록이 비지 않게 된다
EOF
  } | put "$1/lang-python/tests/unit/test_hostile_path_matrix.py"
}

w_rb() {
  { cat <<'EOF'
# frozen_string_literal: true

# 값은 `등록부 id: 한 줄 이유` — "closed-id-one: 주석"
%w[facade_dump_spec tokens_spec].each { |dep| dep }

RSpec.describe "hostile path matrix" do
  NONCE_DROP_EXEMPT = {}.freeze

EOF
    printf '%s\n' "$2"
    cat <<'EOF'

  SERVER = "https://hp.idp.test"
  ANCHOR = %r{ruby/spec/unit/([a-z_]+_spec\.rb)\|(it "[^"]*")}

  it "reads" do
    fails = []
    KNOWN_GAPS.each do |key, why|
      fails << "KNOWN_GAPS[#{key}]: 낡았다(#{why}) #{SERVER}"
    end
    rowed = SERVER.split(/[#.]/).last
    ok = "body".match?(/\.#{rowed}\b/)
    expect(KNOWN_GAPS.key?("x")).to be(false)
    expect(fails).to be_empty, "#{ok} 'closed-id-one: 문자열 안'"
  end
end
EOF
  } | put "$1/lang-ruby/spec/unit/hostile_path_matrix_spec.rb"
}

w_rs() {
  { cat <<'EOF'
//! 값은 `등록부 id: 한 줄 이유` — "closed-id-one: 내부 문서 주석"

/// "closed-id-one: 외부 문서 주석"
const NONCE_DROP_EXEMPT: &[(&str, &str)] = &[];

EOF
    printf '%s\n' "$2"
    cat <<'EOF'

/* 블록 /* 중첩 */ "closed-id-one: 중첩 블록 주석 안" */
fn pick<'a>(s: &'a str) -> &'a str {
    let url = "https://app.example/cb"; // URL
    let raw = r#"raw "closed-id-one: 원시 문자열 안""#;
    let q = '"';
    let multi = "여러
줄 문자열도 rust 에서는 된다";
    for (key, reason) in KNOWN_GAPS {
        println!("KNOWN_GAPS[{key}]: 낡았다({reason}) {url} {raw} {q} {multi}");
    }
    let _ = NONCE_DROP_EXEMPT;
    let _ = format!("panic: {s}"); // 실제 rust 행렬의 줄 — `panic` 도 등록부 id 가 아니다
    let gaps: Vec<(&str, &str)> = KNOWN_GAPS.iter().copied().collect(); // 실제 줄의 모양 — 별칭이 아니라 복사다
    let _ = gaps;
    s
}
EOF
  } | put "$1/lang-rust/tests/hostile_path_matrix.rs"
}

w_cs() {
  { cat <<'EOF'
namespace T;

/// <summary>값은 <c>등록부 id: 한 줄 이유</c> — "closed-id-one: XML 문서 주석"</summary>
public class HostilePathMatrixTests
{
    private static readonly Dictionary<string, string> NonceDropExempt = new(StringComparer.Ordinal);

    // "closed-id-one: 줄 주석"
EOF
    printf '%s\n' "$2"
    cat <<'EOF'

    private const string Url = "https://app.example/cb";
    private static readonly string Path = @"C:\tmp\";
    private static readonly char Q = '"';

    public void Run()
    {
        var fails = new List<string>();
        foreach (var (k, reason) in KnownGaps)
            fails.Add($"KnownGaps[{k}]: 낡았다({reason}) {fails.Count(c => c == "FAIL")} {Url}");
        if (KnownGaps.ContainsKey("x")) fails.Add(Path + Q + NonceDropExempt.Count);
        var raw = """
            "closed-id-one: 원시 문자열 안"
            """;
    }
}
EOF
  } | put "$1/lang-dotnet/tests/T/HostilePathMatrixTests.cs"
}

# 오늘 아홉 행렬의 빈 선언 그대로(철자까지).
D_GO='var hpKnownGaps = map[string]string{}'
D_JAVA='  static final Map<String, String> KNOWN_GAPS = Map.of();'
D_KT='private val HP_KNOWN_GAPS: Map<String, String> = emptyMap()'
D_TS='const KNOWN_GAPS: Readonly<Record<string, string>> = {}'
D_PHP='    private const KNOWN_GAP_GROUPS = [];'
D_PY='_KNOWN_GAPS: dict[str, str] = {}'
D_RB='  KNOWN_GAPS = {}.freeze'
D_RS='const KNOWN_GAPS: &[(&str, &str)] = &[];'
D_CS='    private static readonly Dictionary<string, string> KnownGaps = new(StringComparer.Ordinal);'

# 언어 = 최상위 디렉터리 중 자기 루트에 빌드 매니페스트를 가진 것(`df_tree_langs`).
# 이름을 실제 아홉과 **다르게** 둔다 — 파생을 실제 아홉의 상수로 바꾸면 거의 모든 칸이 빨개진다.
manifests() {
  for m in lang-go/go.mod lang-java/pom.xml lang-kotlin/build.gradle.kts lang-node/package.json \
    lang-php/composer.json lang-python/pyproject.toml lang-ruby/x.gemspec lang-rust/Cargo.toml lang-dotnet/x.sln; do
    printf 'manifest\n' | put "$1/$m"
  done
}

BASE="$TMP/_base"
mkdir -p "$BASE"
git -C "$BASE" init -q
# Windows 의 전역 autocrlf 가 픽스처 줄끝을 바꾼다는 경고를 끈다(내용은 LF 그대로 쓴다).
git -C "$BASE" config core.autocrlf false
registry "$BASE"
manifests "$BASE"
w_go "$BASE" "$D_GO"; w_java "$BASE" "$D_JAVA"; w_kt "$BASE" "$D_KT"; w_ts "$BASE" "$D_TS"; w_php "$BASE" "$D_PHP"
w_py "$BASE" "$D_PY"; w_rb "$BASE" "$D_RB"; w_rs "$BASE" "$D_RS"; w_cs "$BASE" "$D_CS"
git -C "$BASE" add -A

# fork <이름> → $CASE (기본 픽스처의 사본)
fork() { CASE="$TMP/$1"; cp -R "$BASE" "$CASE"; }
# run → OUT · CODE (가드를 $CASE 에 대고 돌린다. 추적 파일만 세므로 먼저 add 한다)
run() {
  git -C "$CASE" add -A
  set +e
  OUT="$(node "$GUARD" "$CASE" 2>&1)"
  CODE=$?
  set -e
}
expect() { # expect <이름> <종료코드> <출력에 있어야 할 것>
  assert_eq "$2" "$CODE" "[$1] 종료코드 — 출력: $OUT"
  assert_contains "$OUT" "$3" "[$1] 출력에 「$3」"
}

# ═══ (a)·(b) 기본 — 아홉 빈 선언, 닫힌 id 는 주석·중첩 문자열 안에만 있다 ═══════════════
fork base; run
expect base 0 "lang-dotnet"
for L in lang-go lang-java lang-kotlin lang-node lang-php lang-python lang-ruby lang-rust; do
  assert_contains "$OUT" "$L" "[base] 파생된 언어 $L 가 출력에 없다"
done
assert_not_contains "$OUT" "closed-id-one" "[base] 주석·중첩 문자열 안의 닫힌 id 를 참조로 읽었다(주석/문자열 경계가 깨졌다)"

# ═══ (a) 양성 — 값 리터럴 `"<id>: …"` ═══════════════════════════════════════════════
fork open-literal
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "open-id-one: 이유"}'
run; expect open-literal 0 "open-id-one"
assert_contains "$OUT" "OPEN" "[open-literal] 열린 id 를 OPEN 으로 판정해야 한다"

fork closed-literal
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "closed-id-one: 이유"}'
run; expect closed-literal 1 "CLOSED"
assert_contains "$OUT" "closed-id-one" "[closed-literal] 어느 id 가 닫혔는지 지목해야 한다"

fork unregistered
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "no-such-item: 이유"}'
run; expect unregistered 1 "UNREGISTERED"

# 하위 불릿의 언급·들여쓴 체크박스는 등록부 항목이 아니다(정규식을 느슨하게 하면 열림으로 샌다).
fork prose-only
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "phantom-in-prose: 이유"}'
run; expect prose-only 1 "UNREGISTERED"
fork indented-only
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "indented-not-an-item: 이유"}'
run; expect indented-only 1 "UNREGISTERED"

# 콜론 뒤 공백이 없는 오타도 참조다(Grok 레그 지목 — 이 칸 전에는 조용히 빠졌다).
fork no-space-colon
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "closed-id-one:공백 없는 이유"}'
run; expect no-space-colon 1 "CLOSED"

# 실제 id 모양 둘 — 대문자 첫 마디 · 점.
fork id-shapes
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "H9-open-upper-segment: 이유", "W3b r/v": "php-thing-0.44-open: 이유"}'
run; expect id-shapes 0 "H9-open-upper-segment"
assert_contains "$OUT" "php-thing-0.44-open" "[id-shapes] 점이 든 id 를 놓쳤다"

# ═══ (a) 양성 — 역사적 계산형 모양(id 가 다른 상수·도우미에 있다) ═══════════════════════════
# kotlin @73d48a1 모양: id 는 상수, 목록은 행에서 펼친다.
D_KT_COMPUTED="$(cat <<'EOF'
private const val HP_GAP_ADMIN_TOKEN_TYPE =
    "open-id-one: admin 내장 TokenManager 가 강제변환한다 " +
        "(둘째 조각)"

private val HP_GAP_ADMIN_ROWS = listOf("admin.ClientsResource.create", "admin.ClientsResource.delete")

private val HP_KNOWN_GAPS: Map<String, String> =
    HP_GAP_ADMIN_ROWS
        .flatMap { row -> listOf("at:12345", "at:true").map { "W3a $row/$it" to HP_GAP_ADMIN_TOKEN_TYPE } }
        .toMap()
EOF
)"
fork kotlin-computed; w_kt "$CASE" "$D_KT_COMPUTED"
run; expect kotlin-computed 0 "open-id-one"

# java @986a96e 모양: 도우미 메서드 안의 지역 변수.
D_JAVA_HELPER="$(cat <<'EOF'
  static final Map<String, String> KNOWN_GAPS = knownGaps();

  private static Map<String, String> knownGaps() {
    Map<String, String> out = new java.util.TreeMap<>();
    String why = "closed-id-two: admin-client TokenManager 의 Jackson 이 "
        + "비문자열·빈 access_token 을 강제변환한다";
    for (String row : java.util.List.of("ClientsResource.get(String)")) out.put("W3a " + row + "/at:number", why);
    return out;
  }
EOF
)"
fork java-helper; w_java "$CASE" "$D_JAVA_HELPER"
run; expect java-helper 1 "closed-id-two"
assert_contains "$OUT" "CLOSED" "[java-helper] 닫힌 id 를 CLOSED 로 판정해야 한다"

# python @0eae924 모양: 괄호 안 암시적 이어붙이기 + 컴프리헨션.
D_PY_CONCAT="$(cat <<'EOF'
_SYNC_ADMIN_EMPTY_BEARER = (
    "open-id-one: sync admin 의 자체 "
    "client_credentials 그랜트가 `Authorization: Bearer ` 로 보낸다"
)

_KNOWN_GAPS: dict[str, str] = {
    f'W3a keycloak_sdk.admin.{module}.{cls}.{method}/at:""': _SYNC_ADMIN_EMPTY_BEARER
    for module, cls, methods in (("clients", "ClientsResource", ("create", "delete")),)
    for method in methods
}
EOF
)"
fork python-concat; w_py "$CASE" "$D_PY_CONCAT"
run; expect python-concat 0 "open-id-one"

# php @569300a 모양: 등록부 id 를 키로 한 묶음(`'<id>' => [...]`).
D_PHP_GROUP="$(cat <<'EOF'
    private const KNOWN_GAP_GROUPS = [
        'closed-id-one' => [
            'reason' => 'admin 의 토큰 부여 예외를 원본째 단다',
            'axis' => 'a',
            'rows' => ['Admin\\ClientsResource::all', 'Admin\\ClientsResource::delete'],
            'variants' => ['b2', 'd'],
        ],
    ];
EOF
)"
fork php-group; w_php "$CASE" "$D_PHP_GROUP"
run; expect php-group 1 "closed-id-one"

# ═══ (a) 양성 — 아홉 문법 각자의 문자열 표기(원시·verbatim·%q·f-string·템플릿·묶음 키) ═══════
D_GO_N='var hpKnownGaps = map[string]string{"W3a r/v": `@ID@: 원시 문자열`}'
D_JAVA_N='  static final Map<String, String> KNOWN_GAPS = Map.of("W3a r/v", "@ID@: 이유");'
D_KT_N='private val HP_KNOWN_GAPS: Map<String, String> = mapOf("W3a r/v" to """@ID@: 원시 문자열""")'
D_TS_N="const KNOWN_GAPS: Readonly<Record<string, string>> = { 'W3a r/v': \`@ID@: \${URL_ARG}\` }"
D_PHP_N="    private const KNOWN_GAP_GROUPS = ['@ID@' => ['reason' => 'x', 'axis' => 'a', 'rows' => ['R::m'], 'variants' => ['v']]];"
D_PY_N='_KNOWN_GAPS: dict[str, str] = {"W3a r/v": f"@ID@: {_URL}"}'
D_RB_N='  KNOWN_GAPS = { "W3a r/v" => %q(@ID@: 퍼센트 문자열) }.freeze'
D_RS_N='const KNOWN_GAPS: &[(&str, &str)] = &[("W3a r/v", r#"@ID@: 원시 문자열"#)];'
D_CS_N='    private static readonly Dictionary<string, string> KnownGaps = new(StringComparer.Ordinal) { ["W3a r/v"] = @"@ID@: verbatim" };'
natives() { # $1=id → 아홉 파일 전부를 그 id 를 실은 비지 않은 선언으로
  w_go "$CASE" "$(printf '%s' "$D_GO_N" | sed "s/@ID@/$1/")"
  w_java "$CASE" "$(printf '%s' "$D_JAVA_N" | sed "s/@ID@/$1/")"
  w_kt "$CASE" "$(printf '%s' "$D_KT_N" | sed "s/@ID@/$1/")"
  w_ts "$CASE" "$(printf '%s' "$D_TS_N" | sed "s/@ID@/$1/")"
  w_php "$CASE" "$(printf '%s' "$D_PHP_N" | sed "s/@ID@/$1/")"
  w_py "$CASE" "$(printf '%s' "$D_PY_N" | sed "s/@ID@/$1/")"
  w_rb "$CASE" "$(printf '%s' "$D_RB_N" | sed "s/@ID@/$1/")"
  w_rs "$CASE" "$(printf '%s' "$D_RS_N" | sed "s/@ID@/$1/")"
  w_cs "$CASE" "$(printf '%s' "$D_CS_N" | sed "s/@ID@/$1/")"
}
fork natives-open; natives open-id-one; run
expect natives-open 0 "open-id-one"
_n="$(printf '%s\n' "$OUT" | grep -c '^OPEN ' || true)"
assert_eq "9" "$_n" "[natives-open] 아홉 문법 각자의 표기에서 id 를 하나씩 찾아야 한다 — 출력: $OUT"

fork natives-closed; natives closed-id-one; run
expect natives-closed 1 "CLOSED"
_n="$(printf '%s\n' "$OUT" | grep -c '^::error::CLOSED ' || true)"
assert_eq "9" "$_n" "[natives-closed] 아홉 언어 전부에서 닫힌 id 를 지목해야 한다 — 출력: $OUT"

# ═══ (c) 공허 — 비지 않은 목록인데 id 를 못 찾았다 → 통과가 아니라 실패 ═══════════════════
fork nonempty-no-id
w_rs "$CASE" "$(printf '%s\n' 'const REASON: &str = "등록부 id 가 없는 이유";' 'const KNOWN_GAPS: &[(&str, &str)] = &[("W3a r/v", REASON)];')"
run; expect nonempty-no-id 2 "FAIL"

# 주석 속의 열린 id 는 「id 가 있다」를 채우지 못한다(trap (o) — 주석이 존재 요건을 채우는 부류).
D_TS_COMMENT_ONLY="$(cat <<'EOF'
// "open-id-one: 주석에만 있다"
const GAP_ID = 'open' + '-id-one'
const KNOWN_GAPS: Readonly<Record<string, string>> = Object.fromEntries(['W3a r/v'].map((k) => [k, `${GAP_ID}: 이유`]))
EOF
)"
fork comment-only-id; w_ts "$CASE" "$D_TS_COMMENT_ONLY"
run; expect comment-only-id 2 "FAIL"

# 빈 선언 + 다른 자리에서 채움(id 는 리터럴 접두가 아니다) → 비지 않은 것으로 보고 id 를 요구한다.
D_CS_MUTATED="$(cat <<'EOF'
    private static readonly Dictionary<string, string> KnownGaps = new(StringComparer.Ordinal);
    private const string GapId = "open-id-one";

    static HostilePathMatrixTests()
    {
        KnownGaps.Add("W3a r/v", GapId + ": 이유");
    }
EOF
)"
fork mutated; w_cs "$CASE" "$D_CS_MUTATED"
run; expect mutated 2 "FAIL"

# 빈 모양 + 이름을 안 쓰는 쓰기 셋(Grok 레그가 지목, 이 칸들 전에는 셋 다 「빈 목록」으로 통과했다 — 실측).
D_GO_UNMARSHAL="$(cat <<'EOF'
var hpKnownGaps = map[string]string{}

func init() { _ = json.Unmarshal([]byte(gapsJSON), &hpKnownGaps) }
EOF
)"
fork unmarshal; w_go "$CASE" "$D_GO_UNMARSHAL"
run; expect unmarshal 2 "FAIL"

D_TS_FIELD="$(cat <<'EOF'
const KNOWN_GAPS: Record<string, string> = {}
KNOWN_GAPS.user = `${URL_ARG}`
EOF
)"
fork field-write; w_ts "$CASE" "$D_TS_FIELD"
run; expect field-write 2 "FAIL"

D_PY_ALIAS="$(cat <<'EOF'
_KNOWN_GAPS: dict[str, str] = {}
_ALIAS = _KNOWN_GAPS
_ALIAS["W3a r/v"] = GAP_REASON
EOF
)"
fork alias; w_py "$CASE" "$D_PY_ALIAS"
run; expect alias 2 "FAIL"

# php 정적 프로퍼티 — `$` 는 변수 표지라 `self::$knownGaps[…] =` 가 같은 이름에 쓰는 것이다(이 칸 전에는 빈 목록으로
# 통과했다 — 이름 경계가 `$` 를 식별자 글자로 봤다, 실측).
D_PHP_STATIC="$(cat <<'EOF'
    private static array $knownGaps = [];

    public static function setUpBeforeClass(): void
    {
        $gap = 'open' . '-id-one';
        self::$knownGaps['W3a r/v'] = "$gap: 이유";
    }
EOF
)"
fork php-static; w_php "$CASE" "$D_PHP_STATIC"
run; expect php-static 2 "FAIL"

# 빈 모양이지만 문장이 다음 줄로 이어진다.
D_RB_CONT="$(cat <<'EOF'
  KNOWN_GAPS = {}
    .merge(OTHER_GAPS)
    .freeze
EOF
)"
fork continued; w_rb "$CASE" "$D_RB_CONT"
run; expect continued 2 "FAIL"

fork no-decl; w_py "$CASE" '_SOMETHING_ELSE: dict[str, str] = {}'
run; expect no-decl 2 "FAIL"

fork two-decls; w_rb "$CASE" "$(printf '%s\n' '  KNOWN_GAPS = {}.freeze' '  KNOWN_GAPS = {}.freeze')"
run; expect two-decls 2 "FAIL"

# ═══ (c) 공허 — 파생 언어에 행렬이 없거나·둘이거나·읽을 수 없는 문법 ═══════════════════
fork missing-matrix
printf 'manifest\n' | put "$CASE/lang-extra/package.json"
run; expect missing-matrix 2 "lang-extra"

fork two-matrices
w_go "$CASE/lang-go/sub" "$D_GO"
mv "$CASE/lang-go/sub/lang-go/hostile_path_matrix_test.go" "$CASE/lang-go/sub/hostile_path_matrix_test.go"
run; expect two-matrices 2 "FAIL"

fork unknown-ext
printf 'manifest\n' | put "$CASE/lang-extra/package.json"
printf 'let KNOWN_GAPS: [String: String] = [:]\n' | put "$CASE/lang-extra/HostilePathMatrixTests.swift"
run; expect unknown-ext 2 ".swift"

fork unterminated-string
w_java "$CASE" '  static final Map<String, String> KNOWN_GAPS = Map.of("W3a r/v", "open-id-one: 닫히지 않는다);'
run; expect unterminated-string 2 "FAIL"

fork unterminated-comment
w_kt "$CASE" "$(printf '%s\n' '/* 닫히지 않는 블록 주석' "$D_KT")"
run; expect unterminated-comment 2 "FAIL"

# ═══ (c) 공허 — 등록부 ═══════════════════════════════════════════════════════════════
fork registry-missing; rm "$CASE/docs/superpowers/plans/remaining-work.md"
run; expect registry-missing 2 "FAIL"

# 체크박스 문법이 바뀌어 항목을 0 개 읽으면 「모든 id 가 미등록」이 아니라 추출 실패다.
fork registry-vacuous
sed 's/^- \[\(.\)\]/* [\1]/' "$CASE/docs/superpowers/plans/remaining-work.md" > "$CASE/r.tmp"
mv "$CASE/r.tmp" "$CASE/docs/superpowers/plans/remaining-work.md"
run; expect registry-vacuous 2 "FAIL"

fork registry-no-closed
grep -v '^- \[x\]' "$CASE/docs/superpowers/plans/remaining-work.md" > "$CASE/r.tmp"
mv "$CASE/r.tmp" "$CASE/docs/superpowers/plans/remaining-work.md"
run; expect registry-no-closed 2 "FAIL"

fork registry-dup
printf '%s\n' '- [x] `open-id-one` 같은 id 가 두 번 — 열림이면서 닫힘' >> "$CASE/docs/superpowers/plans/remaining-work.md"
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "open-id-one: 이유"}'
run; expect registry-dup 2 "open-id-one"

fork registry-grammar
printf '%s\n' '- [ ] `Bad_Id_Here` 추출 문법 밖의 id — 참조를 못 찾는다' >> "$CASE/docs/superpowers/plans/remaining-work.md"
run; expect registry-grammar 2 "Bad_Id_Here"

fork registry-state
sed 's/^- \[ \] `open-id-one`/- [-] `open-id-one`/' "$CASE/docs/superpowers/plans/remaining-work.md" > "$CASE/r.tmp"
mv "$CASE/r.tmp" "$CASE/docs/superpowers/plans/remaining-work.md"
w_go "$CASE" 'var hpKnownGaps = map[string]string{"W3a r/v": "open-id-one: 이유"}'
run; expect registry-state 2 "open-id-one"

# ═══ (c) 공허 — 언어 0 · 그리고 파생이 트리를 읽는다는 양성 ═══════════════════════════════
CASE="$TMP/no-langs"; mkdir -p "$CASE"; git -C "$CASE" init -q; registry "$CASE"
run; expect no-langs 2 "FAIL"

CASE="$TMP/subset"; mkdir -p "$CASE"; git -C "$CASE" init -q; registry "$CASE"
printf 'manifest\n' | put "$CASE/lang-go/go.mod"; w_go "$CASE" "$D_GO"
printf 'manifest\n' | put "$CASE/lang-rust/Cargo.toml"; w_rs "$CASE" "$D_RS"
run; expect subset 0 "lang-rust"
assert_contains "$OUT" "lang-go" "[subset] 파생된 lang-go 가 없다"
assert_not_contains "$OUT" "lang-java" "[subset] 트리에 없는 언어를 말한다 — 파생이 아니라 목록이다"

assert_report
