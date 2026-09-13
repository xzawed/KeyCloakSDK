#!/usr/bin/env sh
# 변이 프로브 러너 — **fail-closed**. 가드가 변이를 잡는지 재는 유일한 지원 경로다.
#
# 왜 도구인가: 이 저장소는 아래 넷을 이미 **규칙으로** 갖고 있었다(작업 프로세스 ⑤⑥ ·
# 루트 CLAUDE.md). 그럼에도 한 세션에서 여섯 번 어겼고, 그중 하나는 **교훈을 적은 뒤
# 같은 날 재발**했다. 적힌 규칙은 구속하지 않는다 — 연산이 거부해야 구속한다.
#
# 이 러너가 기계로 막는 것:
#   (1) 커밋하지 않은 작업 위에서 변이를 돌리는 것 — 복원 단계가 그 작업을 지운다.
#       (실측: `git checkout -- .` 가 완성된 미커밋 작업 11파일을 두 번 되돌렸다.)
#   (2) 본 작업 트리에서 변이하는 것 — 변이는 언제나 버리는 워크트리에서 일어난다.
#   (3) **기준선이 이미 빨간 채로 재는 것** — 그러면 "잡았다"가 변이 때문인지 알 수 없다.
#   (4) **변이가 적용되지 않은 것을 「가드가 침묵했다」로 읽는 것** — 이 부류가 두 번
#       거짓 구멍을 만들었다(`sed` 이스케이프 · `node -e` 의 `\s` 가 두 번 먹힘).
#
# ⚠️ **종료코드가 셋인 것이 요점이다.** 「구멍」과 「프로브 무효」가 같은 코드면 (4)가
# 다시 일어난다.
#   0 = CAUGHT  변이를 가드가 잡았다
#   1 = SILENT  변이가 실제로 적용됐는데 가드가 통과했다 → 진짜 구멍
#   2 = INVALID 프로브가 성립하지 않았다(더러운 트리 · 빨간 기준선 · 변이 미적용)
#
# 사용:
#   scripts/probe.sh '<변이 명령>' <검사 명령...>
# 예:
#   scripts/probe.sh "sed -i 's/ kotlin//' harness/verify.sh" sh scripts/test/test-deploy-facts.sh
#
# 변이 명령과 검사 명령은 **워크트리 안에서** 돈다. 본 트리는 손대지 않는다.
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 '<mutation command>' <check command...>" >&2
  exit 2
fi

MUTATION="$1"
shift

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail_invalid() {
  echo "INVALID: $1" >&2
  exit 2
}

# (1) 커밋이 변이보다 앞 — 미커밋 작업이 있으면 시작하지 않는다.
if [ -n "$(git status --porcelain)" ]; then
  fail_invalid "작업 트리가 깨끗하지 않다. 변이 프로브는 커밋 뒤에만 돈다 — 복원 단계가 미커밋 작업을 지운다(실측 2회)."
fi

# (2) 버리는 워크트리. 본 트리는 이 스크립트가 끝날 때까지 읽기만 한다.
WT="$(mktemp -d)"
cleanup() { git worktree remove "$WT" --force >/dev/null 2>&1 || true; rm -rf "$WT" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
rm -rf "$WT"
git worktree add --detach "$WT" HEAD >/dev/null 2>&1 || fail_invalid "워크트리를 만들지 못했다."

# (3) 기준선 — 변이 전에 검사 명령이 통과해야 한다.
if ! ( cd "$WT" && "$@" ) >/dev/null 2>&1; then
  fail_invalid "기준선이 이미 실패한다. 이 상태에서 '잡았다'는 변이 때문인지 알 수 없다."
fi

# (4) 변이가 실제로 트리를 바꿨는지 본다 — 안 바꿨으면 「침묵」이 아니라 무효다.
( cd "$WT" && eval "$MUTATION" ) >/dev/null 2>&1 || fail_invalid "변이 명령이 비영으로 끝났다: $MUTATION"
# ⚠️ **`git status --porcelain` 으로 재면 안 된다 — 줄끝만 바뀌어도 비지 않는다.** Windows 에서
# `sed -i` 는 매치가 하나도 없어도 파일을 다시 쓰고, 그 과정에서 CRLF 가 LF 로(또는 그 반대로)
# 바뀐다. `status` 는 그것을 「변경」으로 보고하므로 **아무것도 안 바뀐 변이가 `SILENT`(진짜 구멍)
# 로 보고된다** — 이 러너가 막으려고 만들어진 바로 그 부류다(실측 2026-09-07: sed 패턴에 점이
# 하나 많아 매치 0건이었는데 게이트 삭제 프로브 셋이 전부 거짓 `SILENT` 을 냈다).
# `git diff` 는 `.gitattributes`/`autocrlf` 의 정규화를 거치므로 줄끝만 바뀐 것은 비어 있다.
# 새로 만들어진 파일은 `diff` 가 못 보므로 untracked 를 따로 더한다.
CHANGED="$(cd "$WT" && { git diff --name-only; git ls-files --others --exclude-standard; })"
if [ -z "$CHANGED" ]; then
  fail_invalid "변이가 트리의 **내용**을 바꾸지 않았다(줄끝만 바뀐 것은 변경으로 세지 않는다) — 이스케이프·패턴을 의심하라. 이것을 '가드가 침묵했다'로 읽으면 거짓 구멍이 된다."
fi
echo "변이가 바꾼 파일:"
printf '%s\n' "$CHANGED" | sed 's/^/  /'
# ⚠️ **파일명만으로는 부족하다 — 내용을 보여야 한다.** 「맞는 파일에 틀린 내용」이 이 러너의
# 가장 비싼 사각이었다(실측 2026-09-12): perl 이 치환문의 `$VAR` 를 자기 변수로 보간해 변이가
# 「상수 반환」이 아니라 「빈 문자열 반환」이 됐고, 다른 한 번은 perl 문법(`q{}`)이 셸 파일에
# 그대로 들어갔다. **둘 다 `CAUGHT` 로 위장했다** — 파일명은 맞았기 때문이다. diff 를 보면
# 두 경우 다 한눈에 틀렸다.
echo "변이 diff:"
( cd "$WT" && git diff -- . ; git -C "$WT" ls-files --others --exclude-standard \
  | while read -r _f; do printf '+++ (신규) %s\n' "$_f"; sed 's/^/+/' "$WT/$_f" 2>/dev/null | head -20; done ) \
  | head -80 | sed 's/^/  /'

# 판정.
# ⚠️ 검사 명령의 출력을 **버리지 않는다.** 「계측기가 죽은 것」과 「가드가 잡은 것」은 종료코드가
# 같다(실측: 가드 사본을 인자 없이 돌려 ENOENT 로 죽은 것을 `CAUGHT` 으로 읽었다). 잡혔다면
# **무엇이 잡았는지**가 화면에 있어야 한다.
_out="$(cd "$WT" && "$@" 2>&1)" && _rc=0 || _rc=$?
if [ "$_rc" = 0 ]; then
  echo "SILENT — 변이가 적용됐는데 검사 명령이 통과했다(진짜 구멍)."
  exit 1
fi
echo "CAUGHT — 검사 명령이 변이를 잡았다. 잡은 근거(검사 출력 끝):"
printf '%s\n' "$_out" | tail -12 | sed 's/^/  /'
exit 0