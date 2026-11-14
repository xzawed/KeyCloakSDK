#!/usr/bin/env sh
# check-dependabot-updates.mjs 의 자가테스트 — 네트워크 없이 판정 함수와 진입점을 태운다.
#
# 검사 대상은 「지금 Dependabot 이 건강한가」가 아니라 **이 장치가 거짓 초록을 내지 않는가**다. 대상별 마지막
# 실행이 실패인데 초록이거나, 응답이 목록이 아닌데 「실패 없음」이 되거나, Dependabot 이 꺼졌는데 조용하면 있으나
# 마나다(등록부 dependabot-updater-failure-blind — 실측 2026-11-14: ruby bundler 업데이트가 09-17 부터 매주
# 실패했고 어떤 CI 에도 닿지 않았다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../check-dependabot-updates.mjs"

NOW='2026-11-14T12:00:00Z'
# 모듈 경로를 **인자로 넘기지 않는다** — 그 값이 process.argv[1] 이 되어 진입점 가드가 main() 을 돌린다
# (네트워크를 때린다). scripts/ 로 cd 한 뒤 cwd 상대 지정자로 import 한다. 출력이 비면 즉시 죽는다 — 모듈
# 로드에 실패해 양쪽이 빈 문자열이 되면 비교가 공허하게 통과한다.
verdict() { # <runs-json> → 첫 줄 "targets=N", 이어서 실패 줄들(없으면 "(초록)") · 던지면 "THROW …"
  _o="$(cd "$DIR/.." && printf '%s' "$1" | NOW="$NOW" node -e '
    import("./check-dependabot-updates.mjs").then(({ updatesVerdict }) => {
      let s = ""
      process.stdin.on("data", (d) => (s += d)).on("end", () => {
        let v
        try { v = updatesVerdict(JSON.parse(s), Date.parse(process.env.NOW)) } catch (e) { process.stdout.write("THROW " + e.message); return }
        process.stdout.write("targets=" + v.targets + "\n" + (v.failing.join("\n") || "(초록)"))
      })
    })')"
  if [ -z "$_o" ]; then
    printf 'FATAL: updatesVerdict() 가 빈 출력을 냈다 — 모듈 로드 실패로 테스트가 공허해진다\n' >&2
    exit 1
  fi
  printf '%s' "$_o"
}
run() { # <제목> <결론> <생성 시각> [상태] → 실행 하나(gh run list --json 의 모양)
  printf '{"databaseId":7,"status":"%s","conclusion":"%s","createdAt":"%s","displayTitle":"%s"}' "${4:-completed}" "$2" "$3" "$1"
}

# ── 1. 건강하면 초록이고, 대상을 센다 ──────────────────────────────────────
OK="[$(run 'bundler in /ruby - Update #1' success 2026-11-12T23:33:22Z),$(run 'npm_and_yarn in /node - Update #2' success 2026-11-13T01:00:00Z)]"
assert_contains "$(verdict "$OK")" '(초록)' '대상마다 마지막 실행이 성공이면 초록'
assert_contains "$(verdict "$OK")" 'targets=2' '대상 둘을 센다'

# ── 2. 실측 모양 — 대상의 마지막 실행이 실패면 빨갛고, 그 대상을 이름으로 말한다 ─────────
RED="[$(run 'bundler in /ruby - Update #1699586708' failure 2026-11-12T23:33:22Z),$(run 'bundler in /ruby - Update #1684162671' success 2026-11-05T23:33:35Z),$(run 'npm_and_yarn in /node - Update #3' success 2026-11-13T01:00:00Z)]"
assert_contains "$(verdict "$RED")" 'bundler in /ruby — 마지막 실행이 failure' '마지막 실행이 실패인 대상을 이름으로 말한다'
assert_not_contains "$(verdict "$RED")" 'npm_and_yarn' '건강한 대상은 말하지 않는다'
assert_not_contains "$(verdict "$RED")" '(초록)' '⚠️ 마지막 실행이 실패면 초록이 아니다(이 장치가 있는 이유)'
for _c in startup_failure timed_out; do
  assert_not_contains "$(verdict "[$(run 'pip in /python - Update #4' "$_c" 2026-11-13T00:00:00Z)]")" '(초록)' "$_c 도 실패다"
done

# ── 3. 회복하면 풀린다 — 옛 실패가 영구 빨강으로 남으면 곧 무시당한다 ──────────────
BACK="[$(run 'bundler in /ruby - Update #1' failure 2026-11-05T23:33:35Z),$(run 'bundler in /ruby - Update #2' success 2026-11-12T23:33:22Z)]"
assert_contains "$(verdict "$BACK")" '(초록)' '실패 뒤 성공이면 초록'

# ── 4. 한 의존성만 겨눈 실행(보안 업데이트 · 개별 업데이트)은 그 디렉터리 대상으로 접힌다 ───────
# 실측: 10-31 의 `npm_and_yarn in /node for minimatch` 셋은 security_update_not_possible 이었고 그 뒤 정기
# 실행이 성공했다. 접지 않으면 그 제목은 다시 오지 않아 영구 빨강이 된다.
SEC="[$(run 'npm_and_yarn in /node for minimatch - Update #1668382982' failure 2026-11-10T19:00:13Z),$(run 'npm_and_yarn in /node - Update #5' success 2026-11-12T01:00:00Z)]"
assert_contains "$(verdict "$SEC")" '(초록)' '단건 실패 뒤 그 디렉터리의 정기 실행이 성공하면 초록'
assert_contains "$(verdict "$SEC")" 'targets=1' '단건 제목은 디렉터리 대상 하나로 접힌다'
SEC2="[$(run 'npm_and_yarn in /node - Update #5' success 2026-11-10T01:00:00Z),$(run 'bundler in /ruby for webmock, faraday, net-http - Update #1646709995' failure 2026-11-12T02:51:59Z)]"
assert_contains "$(verdict "$SEC2")" 'bundler in /ruby — 마지막 실행이 failure' '여러 의존성을 겨눈 제목도 「생태계 in 디렉터리」로 접는다'
assert_not_contains "$(verdict "$SEC2")" 'webmock' '대상 이름에 의존성 목록이 섞이지 않는다'

# ── 5. 창(14 일) 밖의 대상은 보지 않는다 — 디렉터리를 옮겨 은퇴한 표기가 영구 빨강이 되지 않게 ─────
OLD="[$(run 'github_actions in / - Update #6' failure 2026-10-20T00:00:00Z),$(run 'npm_and_yarn in /node - Update #7' success 2026-11-12T01:00:00Z)]"
assert_contains "$(verdict "$OLD")" '(초록)' '창 밖의 옛 실패는 판정에 들지 않는다'
assert_contains "$(verdict "$OLD")" 'targets=1' '창 밖의 대상은 세지 않는다'

# ── 6. Dependabot 이 꺼진 것은 「실패 없음」이 아니다 ────────────────────────────
STALE="[$(run 'bundler in /ruby - Update #8' success 2026-11-01T00:00:00Z)]"
assert_contains "$(verdict "$STALE")" '8 일 동안' '8 일 넘게 실행이 없으면 빨강'
assert_contains "$(verdict '[]')" '8 일 동안' '실행이 하나도 없으면 빨강'
assert_contains "$(verdict "[$(run 'x' success not-a-date)]")" '8 일 동안' '시각을 못 읽는 실행은 「돌았다」로 세지 않는다'

# ── 7. 끝나지 않은 실행 — 판정은 끝난 실행으로, 「돌고 있다」는 침묵 판정에만 ──────────────
RUNNING="[$(run 'bundler in /ruby - Update #9' failure 2026-11-12T23:33:22Z),$(run 'bundler in /ruby - Update #10' '' 2026-11-14T11:00:00Z in_progress)]"
assert_contains "$(verdict "$RUNNING")" 'bundler in /ruby — 마지막 실행이 failure' '돌고 있는 실행이 있어도 마지막으로 끝난 실패는 빨강'
CANCEL="[$(run 'bundler in /ruby - Update #11' success 2026-11-05T00:00:00Z),$(run 'bundler in /ruby - Update #12' cancelled 2026-11-12T00:00:00Z)]"
assert_contains "$(verdict "$CANCEL")" '(초록)' 'cancelled 는 실패가 아니다'

# ── 8. 목록이 아닌 응답은 「실패 없음」이 아니라 던진다(main 이 exit 2 로 받는다) ──────────
for _j in 'null' '{}' '"x"'; do
  assert_contains "$(verdict "$_j")" 'THROW' "배열이 아닌 응답($_j)은 던진다"
done

# ── 9. 진입점 — 실제 프로세스를 PATH 스텁 gh 로 태운다(종료 코드가 계약이다) ─────────────
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
_gh() { # <exit> <stdout 본문> — 본문은 파일로 두고 그대로 낸다(큰따옴표를 벗기지 않게)
  printf '%s' "$2" > "$STUB/gh.body"
  printf '#!/bin/sh\ncat "%s"\nexit %s\n' "$STUB/gh.body" "$1" > "$STUB/gh"
  chmod +x "$STUB/gh"
}
_main() { # → 종료 코드
  PATH="$STUB:$PATH" GITHUB_REPOSITORY=o/r DEPENDABOT_HEALTH_NOW="$NOW" node "$SH" >/dev/null 2>&1 && echo 0 || echo $?
}
_gh 0 "$OK";      assert_eq "0" "$(_main)" '진입점: 건강하면 exit 0'
_gh 0 "$RED";     assert_eq "1" "$(_main)" '진입점: 마지막 실행이 실패인 대상이 있으면 exit 1'
_gh 1 'boom';     assert_eq "2" "$(_main)" '진입점: gh 가 실패하면 exit 2(「모른다」는 건강이 아니다)'
_gh 0 'not json'; assert_eq "2" "$(_main)" '진입점: JSON 이 아니면 exit 2'
_gh 0 'null';     assert_eq "2" "$(_main)" '진입점: 배열이 아니면 exit 2'

assert_report
