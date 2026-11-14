#!/usr/bin/env sh
# scripts/mutation-sweep.mjs 의 자가테스트 — 스윕이 **약한 시험을 SILENT 로 짚고**, 쌍을 트리에서 빠짐없이 뽑는지 본다.
#
# 겨누는 것(등록부 selftests-with-no-negative-case): 자가테스트가 판정기의 거부를 단언하지 않으면 판정기가 늘
# 통과해도 초록이다. 실측(2026-11-14): M1 변이 39 쌍 중 SILENT 3 — 판정 함수만 먹였거나(`decide()`), 종료 코드를
# 버리고(`|| true`) 메시지만 봤다. 이 스윕이 그 부류를 주간으로 잰다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
SWEEP="$DIR/../mutation-sweep.mjs"
M1="$DIR/../lib/m1-exit-neutral.mjs"

# ── 1. 쌍 파생 — 실행하는 판정기만, 주석 · 소싱 · 없는 파일 · 제외는 뺀다 ─────────────────────────
# 모듈 경로를 인자로 넘기지 않는다(진입점 가드가 main 을 돌린다) — scripts/ 로 cd 해 cwd 상대로 import 한다.
pairs() { # <시험 이름> <시험 본문> [제외 JSON] → "pairs=<t×j …>|stale=<…>"
  _o="$(cd "$DIR/.." && printf '%s' "$2" | NAME="$1" EXCL="${3:-[]}" node -e '
    let s = ""
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      import("./mutation-sweep.mjs").then((m) => {
        const r = m.pairsOf([{ name: process.env.NAME, text: s }], (j) => !j.includes("absent"), JSON.parse(process.env.EXCL))
        process.stdout.write("pairs=" + r.pairs.map((p) => p.test + "×" + p.judge).join(" ") + "|stale=" + r.stale.map((e) => e.join("×")).join(" "))
      })
    })')"
  [ -n "$_o" ] || { printf 'FATAL: pairsOf() 가 빈 출력을 냈다 — 모듈 로드 실패로 테스트가 공허해진다\n' >&2; exit 1; }
  printf '%s' "$_o"
}
T1='#!/usr/bin/env sh
. "$DIR/../lib/facts.sh"
# 근거: scripts/check-b.mjs 가 예전에 …
_out="$(node "$DIR/../check-a.mjs" bad 2>&1)" || true
x="$(sh "$DIR/../absent-judge.sh")"
cp "$DIR/../lib/other.sh" "$FX/lib/"
SH="$DIR/../check-s.sh"
set -- --lib
. "$SH"
assert_contains "$body" "sh scripts/check-c.sh <X.Y.Z>" "런북이 부른다"'
_r="$(pairs test-x.sh "$T1")"
assert_contains "$_r" 'test-x.sh×check-a.mjs' '실행하는 판정기는 쌍이다'
assert_not_contains "$_r" 'check-b.mjs' '주석에만 나오는 이름은 쌍이 아니다'
assert_not_contains "$_r" 'facts.sh' '소싱하는 라이브러리는 쌍이 아니다 — M1 트랩이 시험 프로세스 자신을 0 으로 만든다'
assert_not_contains "$_r" 'other.sh' 'scripts/lib/*.sh 는 사본을 만들어도 쌍이 아니다(실측: 두 시험이 픽스처 사본으로 잡혔다)'
assert_not_contains "$_r" 'check-s.sh' '변수를 거쳐 소싱해도 쌍이 아니다(실측: release-request · release-readiness 의 거짓 SILENT)'
assert_not_contains "$_r" 'absent-judge' '트리에 없는 판정기는 쌍이 아니다'
# 따옴표 안의 `sh scripts/…` 는 실행처럼 보인다 — 휴리스틱은 넓게 잡고 제외 표가 좁힌다(이유를 적은 채로).
assert_contains "$_r" 'test-x.sh×check-c.sh' '문자열 속 명령도 일단 쌍으로 잡는다(넓게)'
_r="$(pairs test-x.sh "$T1" '[["test-x.sh","check-c.sh","런북 글자"]]')"
assert_not_contains "$_r" 'check-c.sh' '제외 표가 그 쌍을 뺀다'
assert_contains "$_r" '|stale=' '쓰인 제외는 낡지 않았다'
assert_eq '' "${_r#*|stale=}" '쓰인 제외는 낡은 목록에 없다'
_r="$(pairs test-x.sh "$T1" '[["test-x.sh","check-z.mjs","옛 쌍"]]')"
assert_contains "$_r" 'stale=test-x.sh×check-z.mjs' '파생되지 않는 제외는 낡았다고 짚는다(손 목록이 조용히 썩지 않게)'

# ── 2. 실제 트리 — 계획만(--list). 쌍 하한 · 낡은 제외 0 · 레코드의 정적 유효성 ────────────────────
_o="$(cd "$ROOT" && node "$SWEEP" --list 2>&1)" && _c=0 || _c=$?
assert_eq '0' "$_c" '실제 트리의 계획이 선다(낡은 제외 · 깨진 레코드가 없다)'
assert_contains "$_o" 'M1  test-check-coverage.sh × check-coverage.mjs' '알려진 쌍이 계획에 있다'
assert_contains "$_o" 'M1  test-dependabot-updates.sh × check-dependabot-updates.mjs' '2026-11-14 SILENT 였던 쌍이 계획에 있다'
_n="$(printf '%s\n' "$_o" | grep -c '^M1  ' || true)"
assert_ok test "$_n" -ge 30
# ⚠️ 판정기 칸(` × ` 뒤)만 본다 — M1 줄과 제외 줄 둘 다. 시험 이름 `test-deploy-facts.sh` 도 그 글자를 담아, 그 시험의
# 줄 레코드(`REC test-deploy-facts.sh :: …`)가 생기자 출력 전체의 부분 문자열 검사가 거짓으로 울었다(2026-11-14).
_lib_pairs() { printf '%s\n' "$1" | grep -cE ' × (lib/)?deploy-facts\.sh( —|$)' || true; }
assert_eq '0' "$(_lib_pairs "$_o")" '소싱 라이브러리는 실제 트리에서도 쌍이 아니다'
assert_eq '1' "$(_lib_pairs 'M1  test-x.sh × lib/deploy-facts.sh')" '[대조] M1 줄 판정기 칸의 lib/deploy-facts.sh 를 짚는다'
assert_eq '1' "$(_lib_pairs '--  제외 test-x.sh × lib/deploy-facts.sh — 이유')" '[대조] 제외 줄 판정기 칸의 lib/deploy-facts.sh 도 짚는다'
assert_eq '0' "$(_lib_pairs 'REC test-deploy-facts.sh :: DF7
M1  test-deploy-facts.sh × check-x.mjs')" '[대조] 시험 이름 칸의 deploy-facts.sh 는 쌍이 아니다'

# ── 3. M1 주입기 — 출력은 두고 실패 종료만 0 으로 ─────────────────────────────────────────────
FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT
printf '#!/usr/bin/env node\nconsole.log("verdict")\nprocess.exit(3)\n' > "$FX/a.mjs"
printf 'throw new Error("boom")\n' > "$FX/b.mjs"
printf '#!/usr/bin/env sh\nset -eu\necho verdict\nexit 4\n' > "$FX/c.sh"
printf '#!/usr/bin/env sh\nset -eu\ntrap '"'"'echo cleaned > "$M"'"'"' EXIT\nfalse\n' > "$FX/d.sh"
for f in a.mjs b.mjs c.sh d.sh; do cp "$FX/$f" "$FX/orig-$f"; done
_c=0; node "$FX/a.mjs" >/dev/null 2>&1 || _c=$?
assert_eq '3' "$_c" '대조군: 주입 전 a.mjs 는 exit 3'
_c=0; node "$M1" >/dev/null 2>&1 || _c=$?
assert_eq '2' "$_c" '주입기는 대상 없이 부르면 exit 2'
printf 'x\n' > "$FX/x.txt"
_c=0; node "$M1" "$FX/x.txt" >/dev/null 2>&1 || _c=$?
assert_eq '2' "$_c" '주입기는 모르는 형식을 거부한다(exit 2)'
for f in a.mjs b.mjs c.sh d.sh; do node "$M1" "$FX/$f"; done
_c=0; _out="$(node "$FX/a.mjs" 2>&1)" || _c=$?
assert_eq '0' "$_c" 'process.exit(3) 이 0 이 된다'
assert_contains "$_out" 'verdict' '출력은 그대로다'
_c=0; node "$FX/b.mjs" >/dev/null 2>&1 || _c=$?
assert_eq '0' "$_c" '잡히지 않은 throw 도 0 이 된다'
_c=0; _out="$(sh "$FX/c.sh" 2>&1)" || _c=$?
assert_eq '0' "$_c" 'sh 의 exit 4 가 0 이 된다'
assert_contains "$_out" 'verdict' 'sh 출력도 그대로다'
_c=0; M="$FX/cleaned" sh "$FX/d.sh" >/dev/null 2>&1 || _c=$?
assert_eq '0' "$_c" '판정기 자신의 EXIT 트랩이 있어도 0 이 된다'
assert_eq 'cleaned' "$(cat "$FX/cleaned" 2>/dev/null || true)" '판정기 자신의 정리 처리기는 그대로 돈다'
assert_eq '3' "$(grep -c 'PROBE-M1' "$FX/d.sh" "$FX/a.mjs" | awk -F: '{s+=$2} END{print s}')" '넣은 줄마다 표식이 붙는다(probe --site 가 착지를 본다)'

# ── 4. 끝까지 — 샌드박스 저장소에서 약한 시험은 SILENT, 거부를 단언하는 시험은 CAUGHT ───────────────
SB="$FX/sb"
mkdir -p "$SB/scripts/test" "$SB/scripts/lib"
cp "$DIR/../probe.sh" "$SB/scripts/probe.sh"
cp "$DIR/assert.sh" "$SB/scripts/test/assert.sh"
cp "$SWEEP" "$SB/scripts/mutation-sweep.mjs"
cp "$M1" "$SB/scripts/lib/m1-exit-neutral.mjs"
printf '#!/usr/bin/env node\nif (process.argv[2] === "bad") { console.log("::error::bad"); process.exit(1) }\nconsole.log("ok")\n' > "$SB/scripts/check-x.mjs"
# 거부를 단언하는 시험
printf '#!/usr/bin/env sh\nset -eu\nDIR="$(cd "$(dirname "$0")" && pwd)"\n. "$DIR/assert.sh"\nassert_ok node "$DIR/../check-x.mjs" good\nassert_fails node "$DIR/../check-x.mjs" bad\nassert_report\n' > "$SB/scripts/test/test-good.sh"
# 메시지만 보는 시험 — 이 저장소에서 실제로 SILENT 였던 모양(`|| true` + 메시지)
printf '#!/usr/bin/env sh\nset -eu\nDIR="$(cd "$(dirname "$0")" && pwd)"\n. "$DIR/assert.sh"\n_o="$(node "$DIR/../check-x.mjs" bad 2>&1 || true)"\nassert_contains "$_o" "::error::bad" "메시지"\nassert_report\n' > "$SB/scripts/test/test-weak.sh"
: > "$SB/scripts/test/mutation-records.txt"
(cd "$SB" && git init -q && git config user.email sweep@test.local && git config user.name sweep && git add -A && git commit -qm sandbox) >/dev/null 2>&1
_o="$(cd "$SB" && node scripts/mutation-sweep.mjs 2>&1)" && _c=0 || _c=$?
assert_eq '1' "$_c" '⚠️ 약한 시험이 하나라도 있으면 스윕은 exit 1'
assert_contains "$_o" 'SILENT  M1  test-weak.sh × check-x.mjs' '메시지만 보는 시험을 SILENT 로 짚는다'
assert_contains "$_o" 'CAUGHT  M1  test-good.sh × check-x.mjs' '거부를 단언하는 시험은 CAUGHT'
# 대조군 — 약한 시험을 없애면 초록이다(스윕이 늘 빨갛지 않다).
(cd "$SB" && git rm -q scripts/test/test-weak.sh && git commit -qm drop-weak) >/dev/null 2>&1
_c=0; (cd "$SB" && node scripts/mutation-sweep.mjs >/dev/null 2>&1) || _c=$?
assert_eq '0' "$_c" '약한 시험이 없으면 exit 0'

# ── 5. 줄 레코드 — 정적 유효성(드리프트는 PR 에서 바로) · 돌리면 CAUGHT/SILENT ─────────────────────
rec() { # <id> <file> <test> <old> <new> <site>
  printf '### %s\nFILE:%s\nTEST:%s\nOLD:%s\nNEW:%s\nSITE:%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}
# 잡히는 레코드 — 음성 대조의 입력을 좋은 값으로 바꾸면 그 단언이 넘어진다.
# ⚠️ SITE 에 공백 없는 중괄호 · `${…}` 를 일부러 둔다 — Windows 에서 node 가 MSYS sh 를 띄우면 공백 없는 인자에
# 중괄호 확장이 걸려 `{1,6}NEVER` 가 인자 둘로 갈리고 `${_cpj:+false}` 가 깨져 INVALID 가 났다(실측 2026-11-14,
# S1 레그). 러너는 값을 환경 변수로 넘겨 인자 해석을 거치지 않는다.
rec good-neg scripts/test/test-good.sh scripts/test/test-good.sh \
  'assert_fails node "$DIR/../check-x.mjs" bad' 'assert_fails node "$DIR/../check-x.mjs" good # {a,b}${_x:+y}' '{a,b}${_x:+y}' > "$SB/scripts/test/mutation-records.txt"
(cd "$SB" && git add -A && git commit -qm rec) >/dev/null 2>&1
_o="$(cd "$SB" && node scripts/mutation-sweep.mjs 2>&1)" && _c=0 || _c=$?
assert_eq '0' "$_c" '잡히는 레코드뿐이면 exit 0'
assert_contains "$_o" 'CAUGHT  REC test-good.sh :: good-neg' '줄 레코드를 돌려 CAUGHT 를 짚는다'
# 안 잡히는 레코드 — 결과를 바꾸지 않는 변이는 SILENT 이고 스윕은 빨갛다.
rec noop scripts/test/test-good.sh scripts/test/test-good.sh \
  'assert_ok node "$DIR/../check-x.mjs" good' 'assert_ok node "$DIR/../check-x.mjs" good # same' '# same' >> "$SB/scripts/test/mutation-records.txt"
(cd "$SB" && git add -A && git commit -qm rec2) >/dev/null 2>&1
_o="$(cd "$SB" && node scripts/mutation-sweep.mjs 2>&1)" && _c=0 || _c=$?
assert_eq '1' "$_c" '⚠️ 안 잡히는 레코드가 있으면 exit 1'
assert_contains "$_o" 'SILENT  REC test-good.sh :: noop' '안 잡히는 레코드를 SILENT 로 짚는다'
# 정적 유효성 — OLD 가 없으면 계획부터 서지 않는다(exit 2). 이 검사는 repo-hygiene 에서 PR 마다 돈다.
rec stale scripts/test/test-good.sh scripts/test/test-good.sh 'no such line' 'x' 'x' >> "$SB/scripts/test/mutation-records.txt"
_c=0; (cd "$SB" && node scripts/mutation-sweep.mjs --list >/dev/null 2>&1) || _c=$?
assert_eq '2' "$_c" 'OLD 가 파일에 없는 레코드면 계획이 서지 않는다(exit 2)'

assert_report
