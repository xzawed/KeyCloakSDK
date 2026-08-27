#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
CFG="$DIR/../check-dependabot-alerts.mjs"

# 네트워크·gh 없이 도는 테스트다. 검사 대상은 "지금 경보가 있는가"가 아니라
# **게이트가 거짓 초록을 내지 않는가**다 — 조회에 실패했는데 "경보 없음"으로 끝나거나,
# 판정 함수가 늘 빈 배열을 돌려주게 바뀌면 이 게이트는 있으나 마나가 된다.

# 모듈 경로를 **인자로 넘기면 안 된다** — 그 값이 process.argv[1]이 되어 진입점 가드가
# "직접 실행"으로 오인하고 main()이 돌아버린다(네트워크를 때린다). scripts/로 cd한 뒤
# cwd 상대 지정자로 import한다. 출력이 비면 즉시 죽는다: 모듈 로드에 실패해도 양쪽이
# 빈 문자열이 되면 비교가 **공허하게 통과**하기 때문이다.
verdict() { # <alerts-json> <"len"|"text"> -> 결과
  out="$(cd "$DIR/.." && printf '%s' "$1" | MODE="$2" node -e '
    import("./check-dependabot-alerts.mjs").then(({ alertsVerdict }) => {
      let s = ""
      process.stdin.on("data", (d) => (s += d)).on("end", () => {
        const v = alertsVerdict(JSON.parse(s))
        process.stdout.write(process.env.MODE === "len" ? String(v.length) : v.join("\n") || "(비어있음)")
      })
    })')"
  if [ -z "$out" ]; then
    printf 'FATAL: alertsVerdict()가 빈 출력을 냈다 — 모듈 로드 실패로 테스트가 공허해진다\n' >&2
    exit 1
  fi
  printf '%s' "$out"
}

# ── 1. 열린 경보는 반드시 잡혀야 한다(침묵 금지) ─────────────────────────────
# 픽스처는 실제 사건의 모양이다: harness/apps/ruby/Gemfile 의 puma, 6.x 에 패치가 없어
# `~> 6.4` 가 어떤 수정에도 닿지 못했던 그 경보(GHSA-2vqw-3mp8-cgmx).
OPEN='[{"number":13,"state":"open","dependency":{"package":{"ecosystem":"rubygems","name":"puma"},"manifest_path":"harness/apps/ruby/Gemfile"},"security_advisory":{"severity":"high","ghsa_id":"GHSA-2vqw-3mp8-cgmx","cve_id":"CVE-2026-47737"},"security_vulnerability":{"first_patched_version":{"identifier":"7.2.1"}}}]'
assert_eq "1" "$(verdict "$OPEN" len)" '열린 경보 1건을 잡는다'

# ── 2. 메시지가 실행 가능해야 한다 ───────────────────────────────────────────
# 개수만 뱉는 게이트는 읽는 사람이 Security 탭을 다시 열어야 해서 결국 안 읽힌다.
# 어느 매니페스트인지·무엇으로 고치는지가 출력 안에 있어야 한다.
TEXT="$(verdict "$OPEN" text)"
assert_contains "$TEXT" 'harness/apps/ruby/Gemfile' '출력이 어느 매니페스트인지 알려준다'
assert_contains "$TEXT" 'GHSA-2vqw-3mp8-cgmx' '출력이 advisory 를 알려준다'
assert_contains "$TEXT" '7.2.1' '출력이 패치 버전을 알려준다'
assert_contains "$TEXT" 'high' '출력이 심각도를 알려준다'

# ── 3. 닫힌 경보를 세면 게이트가 영구 빨강이 되어 무시당한다 ────────────────
# 호출부가 `?state=open` 을 붙이지만 그 질의문자열은 오타 하나로 사라진다 — 판정 함수가
# 스스로 한 번 더 거르지 않으면 fixed 35건이 그대로 실패로 둔갑한다(이 저장소의 실제 수치).
CLOSED='[{"number":1,"state":"fixed","dependency":{"package":{"ecosystem":"npm","name":"x"},"manifest_path":"node/package.json"},"security_advisory":{"severity":"low","ghsa_id":"GHSA-x","cve_id":null},"security_vulnerability":{}},
         {"number":2,"state":"dismissed","dependency":{"package":{"ecosystem":"npm","name":"y"},"manifest_path":"node/package.json"},"security_advisory":{"severity":"high","ghsa_id":"GHSA-y","cve_id":null},"security_vulnerability":{}},
         {"number":3,"state":"auto_dismissed","dependency":{"package":{"ecosystem":"npm","name":"z"},"manifest_path":"node/package.json"},"security_advisory":{"severity":"high","ghsa_id":"GHSA-z","cve_id":null},"security_vulnerability":{}}]'
assert_eq "(비어있음)" "$(verdict "$CLOSED" text)" 'fixed·dismissed·auto_dismissed 는 세지 않는다'

# ── 4. 빈 목록을 오탐하지 않는다 ─────────────────────────────────────────────
assert_eq "(비어있음)" "$(verdict '[]' text)" '경보가 없으면 아무것도 보고하지 않는다'

# ── 5. 패치가 없는 경보도 침묵하지 않는다 ───────────────────────────────────
# first_patched_version 이 null 인 advisory 가 있다. 그때 undefined 를 문자열에 그냥 끼워
# 넣으면 "패치: undefined" 같은 출력이 나가고, 더 나쁘게는 예외로 죽어 exit 2 가 된다.
NOFIX='[{"number":9,"state":"open","dependency":{"package":{"ecosystem":"pip","name":"q"},"manifest_path":"python/pyproject.toml"},"security_advisory":{"severity":"critical","ghsa_id":"GHSA-q","cve_id":null},"security_vulnerability":{"first_patched_version":null}}]'
assert_eq "1" "$(verdict "$NOFIX" len)" '패치 없는 경보도 잡는다'
assert_contains "$(verdict "$NOFIX" text)" '패치 없음' '패치가 없으면 그렇게 적는다'

# ── 6. 배열이 아닌 응답은 조용히 초록이 되면 안 된다 ────────────────────────
# 이 게이트의 **유일한 거짓-초록 형태**였다(적대적 리뷰에서 발현). 200 응답이 `null`로
# 파싱되면 `alerts ?? []`가 걷어내 빈 배열이 되고, JSON 문자열이면 `for...of`가 글자를 훑어
# `.state`가 전부 undefined → 역시 빈 배열 → exit 0. 즉 "경보가 없다"와 "읽은 것이 경보
# 목록이 아니다"가 같은 초록이 된다. 던져서 main이 2로 받게 한다.
verdict_throws() { # <json> -> THREW|NO-THROW
  (cd "$DIR/.." && VAL="$1" node -e '
    import("./check-dependabot-alerts.mjs").then(({ alertsVerdict }) => {
      try { alertsVerdict(JSON.parse(process.env.VAL)); process.stdout.write("NO-THROW") }
      catch { process.stdout.write("THREW") }
    })')
}
assert_eq "THREW" "$(verdict_throws 'null')" 'null 응답은 조용히 통과하지 않는다'
assert_eq "THREW" "$(verdict_throws '"no alerts"')" 'JSON 문자열 응답은 글자로 훑어 빈 배열이 되지 않는다'
assert_eq "THREW" "$(verdict_throws '{"message":"Not Found"}')" '객체 응답(오류 봉투)은 조용히 통과하지 않는다'
assert_eq "NO-THROW" "$(verdict_throws '[]')" '정상적인 빈 배열은 던지지 않는다'

# ── 7. 조회 실패는 "경보 없음"이 아니라 exit 2다 ─────────────────────────────
# 이게 이 게이트에서 가장 비싼 실패다: 잡의 permissions 에서 `vulnerability-alerts: read`
# 가 빠지면 API 는 403 을 준다(실측: 대조군 잡). 그걸 0으로 넘기면 게이트는 영원히
# 초록이면서 아무것도 보지 않는다 — 있는 것이 없는 것보다 나쁜 상태다.
set +e
node "$CFG" --repo xzawed/definitely-not-a-real-repo-000 >/dev/null 2>&1
rc=$?
set -e
assert_eq 2 "$rc" '조회 불가는 exit 2(열린 경보 1과 구분한다)'

# ── 8. 워크플로가 그 권한을 실제로 선언하고 있는가 ───────────────────────────
# 실측(run 33079374320): 같은 요청을 보낸 두 잡 중 `vulnerability-alerts: read` 를 선언한
# 쪽은 200, 선언하지 않은 대조군은 403 "Resource not accessible by integration" 이었다.
# `security-events: read` 로 바꿔 달면 code scanning 용이라 듣지 않는다. 그 한 줄이 사라지면
# 이 잡은 매주 exit 2 로 빨개지고, 빨간 게이트는 곧 꺼진다 — 그래서 리터럴을 못박는다.
WF="$ROOT/.github/workflows/security-audit.yml"
assert_ok test -f "$WF"
# ⚠️ 파일 전체에 대한 `assert_contains` 로는 부족하다 — 이 워크플로의 주석이 그 문자열을
# 근거로 인용하고 있어서, **선언을 지우고 주석만 남겨도 통과**한다(test-selftest-hygiene 이
# 같은 부류의 공허함으로 한 번 깨진 전례가 있다). 들여쓰기 + 줄끝으로 YAML 키만 센다.
assert_eq "1" "$(grep -cE '^[[:space:]]+vulnerability-alerts: read[[:space:]]*$' "$WF")" \
  'security-audit.yml 이 vulnerability-alerts: read 를 YAML 키로 선언한다(주석 아님)'
assert_eq "1" "$(grep -cE 'node scripts/check-dependabot-alerts\.mjs' "$WF")" 'security-audit.yml 이 이 가드를 실제로 호출한다'

assert_report
