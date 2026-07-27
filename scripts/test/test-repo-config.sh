#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
CFG="$DIR/../repo-config.mjs"
ROOT="$(cd "$DIR/../.." && pwd)"

# 네트워크·gh 없이 도는 테스트다. 검사 대상은 "GitHub 설정이 맞는가"가 아니라
# **대조기가 거짓 신호를 내지 않는가**다 — 의미 없는 차이(서버 생성 필드·배열 순서)로
# 드리프트를 외치면 아무도 안 보게 되고, 진짜 차이를 놓치면 있으나 마나다.

# 모듈 경로도 argv로 넘긴다(MSYS는 인자만 변환한다 — `-e` 문자열에 박은 경로는
# node가 D:\d\Source\...로 오해해 ERR_MODULE_NOT_FOUND가 난다). 그 실패는 조용하지
# 않아야 한다: 예전 판은 로드 실패 시 양쪽이 빈 문자열이 되어 비교가 **공허하게
# 통과**했다 — 그래서 아래 run_canonical은 출력이 비면 즉시 죽는다.
# ⚠️ 모듈 경로를 **인자로 넘기면 안 된다**. `node -e '<code>' <path>`에서 그 인자는
# process.argv[1]이 되고, repo-config.mjs의 진입점 가드가 바로 그 값과 자기 경로를
# 비교하므로 "직접 실행"으로 오인해 main()이 돌아버린다(= import만 하려던 테스트가
# 네트워크를 때리고 canonical 대신 check 출력을 뱉는다 — 실제로 그렇게 깨졌다).
# scripts/로 cd한 뒤 cwd 상대 지정자로 import하면 인자도, MSYS 경로 변환 문제도 없다.
run_canonical() { # <json> -> canonical json
  out="$(cd "$DIR/.." && printf '%s' "$1" | node -e '
    import("./repo-config.mjs").then(({ canonical }) => {
      let s = ""
      process.stdin.on("data", (d) => (s += d)).on("end", () => {
        process.stdout.write(JSON.stringify(canonical(JSON.parse(s))))
      })
    })')"
  if [ -z "$out" ]; then
    printf 'FATAL: canonical()이 빈 출력을 냈다 — 모듈 로드 실패로 테스트가 공허해진다\n' >&2
    exit 1
  fi
  printf '%s' "$out"
}

# ── 1. 서버 생성 필드는 무시돼야 한다 ────────────────────────────────────────
# GitHub 응답에는 id/created_at/_links가 붙는다. 이것들 때문에 매번 드리프트가
# 뜨면 대조기는 즉시 무용지물이 된다.
A='{"name":"P","rules":[{"type":"deletion"}]}'
B='{"id":123,"node_id":"x","created_at":"2026-01-01","updated_at":"2026-01-02","source":"o/r","source_type":"Repository","current_user_can_bypass":"never","_links":{"self":{"href":"h"}},"name":"P","rules":[{"type":"deletion"}]}'
assert_eq "$(run_canonical "$A")" "$(run_canonical "$B")" '서버 생성 필드는 대조에서 제외'

# ── 2. 배열 순서 차이는 같은 설정으로 봐야 한다 ──────────────────────────────
C='{"rules":[{"type":"deletion"},{"type":"non_fast_forward"}],"m":["merge","squash","rebase"]}'
D='{"m":["rebase","merge","squash"],"rules":[{"type":"non_fast_forward"},{"type":"deletion"}]}'
assert_eq "$(run_canonical "$C")" "$(run_canonical "$D")" '배열 순서 차이는 드리프트가 아니다'

# ── 3. 진짜 의미 차이는 반드시 잡혀야 한다(침묵 금지) ────────────────────────
E='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"doc-facts"}]}}]}'
F='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"doc-facts"},{"context":"shell-exec-bits"}]}}]}'
if [ "$(run_canonical "$E")" = "$(run_canonical "$F")" ]; then
  assert_eq "달라야 함" "같음" '필수 체크가 하나 빠지면 드리프트로 잡힌다'
else
  assert_eq 1 1 '필수 체크가 하나 빠지면 드리프트로 잡힌다'
fi
G='{"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"doc-facts","integration_id":15368}]}}]}'
if [ "$(run_canonical "$E")" = "$(run_canonical "$G")" ]; then
  assert_eq "달라야 함" "같음" 'integration_id 유무는 드리프트로 잡힌다'
else
  assert_eq 1 1 'integration_id 유무는 드리프트로 잡힌다'
fi

# ── 4. 인증/권한 실패는 드리프트(1)가 아니라 2로 끝나야 한다 ─────────────────
# 토큰이 없어서 못 읽은 것을 "설정이 어긋났다"로 보고하면 CI가 거짓말을 하게 된다.
set +e
node "$CFG" check --repo xzawed/definitely-not-a-real-repo-000 >/dev/null 2>&1
rc=$?
set -e
assert_eq 2 "$rc" '접근 불가 저장소는 exit 2(드리프트 1과 구분)'

# ── 5. 커밋된 정의는 유효한 JSON이고 필수 규칙을 담고 있어야 한다 ────────────
DEF="$ROOT/.github/rulesets/main.json"
# 경로는 반드시 argv로 넘긴다 — MSYS는 인자로 온 경로만 Windows 형식으로 변환하고,
# `-e` 스크립트 문자열 안에 박은 경로는 그대로 둬서 node가 D:\d\Source\...로 오해한다.
assert_ok node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$DEF"
HAS="$(node -e "
  const r=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  process.stdout.write(r.rules.map(x=>x.type).sort().join(','));
" "$DEF")"
assert_contains "$HAS" 'required_status_checks' '정의에 required_status_checks 규칙이 있다'
assert_contains "$HAS" 'pull_request' '정의에 pull_request 규칙이 있다'

# ── 6. required로 지정한 컨텍스트는 경로필터 없는 워크플로에서 와야 한다 ─────
# 이게 이 저장소에서 가장 비싼 실수다: 워크플로 레벨 `paths:` 필터가 걸린 잡을
# required로 지정하면 그 경로를 건드리지 않는 PR에서 체크가 **생성되지 않아**
# Pending으로 남고 머지가 영구 차단된다(GitHub 공식 문서). 정의에 적힌 컨텍스트가
# 실제로 무필터 워크플로의 잡인지 기계로 확인한다.
for ctx in $(node -e "
  const r=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  const rule=r.rules.find(x=>x.type==='required_status_checks');
  process.stdout.write(rule.parameters.required_status_checks.map(c=>c.context).join(' '));
" "$DEF"); do
  OWNER="$(grep -rlE "^  $ctx:" "$ROOT/.github/workflows/" || true)"
  assert_contains "$OWNER" '.yml' "required 컨텍스트 '$ctx'를 정의한 워크플로가 존재"
  # 그 워크플로에 paths: 필터가 없어야 한다.
  if grep -qE "^\s+paths:" "$OWNER"; then
    assert_eq "무필터" "paths 있음" "required 컨텍스트 '$ctx'의 워크플로에 경로필터가 없다 ($OWNER)"
  else
    assert_eq 1 1 "required 컨텍스트 '$ctx'의 워크플로에 경로필터가 없다"
  fi
done

assert_report
