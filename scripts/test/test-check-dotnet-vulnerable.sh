#!/usr/bin/env sh
# .NET 취약 패키지 감사 판정(`scripts/check-dotnet-vulnerable.mjs`) 자가테스트 — 픽스처만, dotnet 도 네트워크도 쓰지 않는다.
#
# 픽스처는 실제 `dotnet list <csproj> package --vulnerable --include-transitive [--format json]`(.NET SDK 10.0.102,
# 2026-11-13)이 낸 모양 그대로이고 경로만 중립값(`/work/…`)으로 바꿨다:
#   clean-two-tfms.json      이 저장소 SDK 를 `net8.0;net10.0` 으로 돌린 깨끗한 실행 — `frameworks` 키가 **없다**
#   top-level-one-tfm.json   임시 프로젝트, net8.0 에만 직접 의존 Newtonsoft.Json 12.0.1(GHSA-5crp-9r3c-p9vr, High)
#   top-level-one-tfm.txt    같은 실행의 텍스트 출력 — 옛 grep 판정이 통과시킨 그것
#   transitive-one-tfm.json  net8.0 에만 Newtonsoft.Json.Bson 1.0.2 → 전이 Newtonsoft.Json 12.0.1
#   http-source-refused.json HTTP 소스를 준 실행 — `projects` 는 깨끗한 실행과 같은 모양이고 `problems` 만 다르다
#   network-failure.txt      닿지 않는 HTTPS 소스 — JSON 이 아니라 오류 텍스트(종료코드 1)
# 손으로 만든 둘: no-transitive.json(`--include-transitive` 없이 감사) · no-projects.json(빈 `projects`).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
G="$DIR/../check-dotnet-vulnerable.mjs"
F="$DIR/fixtures/dotnet-vulnerable"
rc() { node "$G" "$@" >/dev/null 2>&1 && echo 0 || echo $?; }

# ── 판정 셋 ──────────────────────────────────────────────────────────────────────────────
assert_eq 0 "$(rc "$F/clean-two-tfms.json")" '깨끗한 보고서 → 0'
assert_eq 1 "$(rc "$F/top-level-one-tfm.json")" '한 대상에만 있는 직접 의존 취약점 → 1'
assert_eq 1 "$(rc "$F/transitive-one-tfm.json")" '한 대상에만 있는 전이 의존 취약점 → 1'

# ── 판정 불가는 깨끗함과 갈린다 ───────────────────────────────────────────────────────────
assert_eq 2 "$(rc "$F/http-source-refused.json")" 'problems 가 있으면 판정 불가(projects 는 깨끗한 모양이다)'
assert_eq 2 "$(rc "$F/network-failure.txt")" 'JSON 이 아니면 판정 불가'
assert_eq 2 "$(rc "$F/no-transitive.json")" '--include-transitive 없이 감사한 보고서는 판정 불가'
assert_eq 2 "$(rc "$F/no-projects.json")" '감사한 프로젝트가 없으면 판정 불가'
assert_eq 2 "$(rc "$F/does-not-exist.json")" '파일이 없으면 판정 불가'
assert_eq 2 "$(rc)" '인자가 없으면 판정 불가'

# ── 무엇이 왜 걸렸는지 댄다 ───────────────────────────────────────────────────────────────
OUT="$(node "$G" "$F/top-level-one-tfm.json" 2>&1 || true)"
assert_contains "$OUT" 'net8.0 · top-level · Newtonsoft.Json 12.0.1 · High' '대상 · 직접/전이 · 패키지 · 심각도를 댄다'
assert_not_contains "$OUT" 'net10.0 ·' '깨끗한 대상은 걸린 것으로 나열하지 않는다'
OUT="$(node "$G" "$F/transitive-one-tfm.json" 2>&1 || true)"
assert_contains "$OUT" 'net8.0 · transitive · Newtonsoft.Json 12.0.1' '전이 의존도 대상과 함께 댄다'
OUT="$(node "$G" "$F/http-source-refused.json" 2>&1 || true)"
assert_contains "$OUT" 'NuGet requires HTTPS sources' 'problems 의 문구를 그대로 옮긴다'

# ── 옛 판정이 왜 바뀌었는가의 박제 ─────────────────────────────────────────────────────────
# 같은 실행의 텍스트 출력에서 옛 판정(`grep -qi "no vulnerable packages"`)은 **깨끗한 대상의 줄**에 걸려 통과했다.
if grep -qi "no vulnerable packages" "$F/top-level-one-tfm.txt"; then old=pass; else old=fail; fi
assert_eq pass "$old" '옛 grep 판정은 한 대상만 취약한 텍스트 출력을 통과시켰다'

assert_report
