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
#   scripts/probe.sh --site '<의도한 자리 패턴>' '<변이 명령>' <검사 명령...>
#   scripts/probe.sh --no-site                  '<변이 명령>' <검사 명령...>
# 예:
#   scripts/probe.sh --site "SD_LANGS='java" "sed -i ... " sh scripts/test/test-deploy-facts.sh
#
# ⚠️ **`--site` 는 「변이가 의도한 자리를 쳤는가」를 기계가 거부하게 만든다.** 이것이 없을 때
# 무슨 일이 났는지는 실측돼 있다(2026-09-12): perl 이 치환문의 `$SD_LANGS` 를 **자기 변수로**
# 보간해 변이가 「상수 반환」이 아니라 「빈 문자열 반환」이 됐는데, 변이는 **착지했고** 가드가
# 그 빈 값을 잡아 `CAUGHT` 이 났다 — 의도한 변이는 한 번도 시험되지 않은 채 성공으로 기록됐다.
# 두 번째 시도는 perl 문법(`q{}`)을 셸 파일에 그대로 써 넣고 또 `CAUGHT` 이었다.
# 「diff 를 눈으로 본다」는 **첫 단계에 대한 희망**이지 두 번째 단계가 아니다.
#
# ⚠️ 둘 중 하나는 **반드시** 줘야 한다. 생략을 기본값으로 두면 아무도 안 쓴다 —
# `--no-site` 는 「이번엔 안 본다」를 **보이는 선택**으로 만든다(경고를 찍는다).
#
# 변이 명령과 검사 명령은 **워크트리 안에서** 돈다. 본 트리는 손대지 않는다.
set -eu

SITE=''
SITE_MODE=''
RELEVANCE_MODE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --site)    [ "$#" -ge 2 ] || { echo "usage: --site 에 패턴이 없다" >&2; exit 2; }
               SITE="$2"; SITE_MODE=declared; shift 2 ;;
    --no-site) SITE_MODE=waived; shift ;;
    --assume-relevant) RELEVANCE_MODE=waived; shift ;;
    *)         break ;;
  esac
done

if [ -z "$SITE_MODE" ]; then
  echo "usage: $0 --site '<의도한 자리 패턴>' | --no-site   '<변이 명령>' <검사 명령...>" >&2
  echo "  ⚠️ 의도한 자리를 선언하거나, 안 보겠다고 명시하라 — 둘 다 안 하면 돌지 않는다." >&2
  echo "     (근거: 변이가 착지했지만 **다른 것이 된** 채 CAUGHT 으로 기록된 사고 2건, 2026-09-12)" >&2
  exit 2
fi

if [ "$#" -lt 2 ]; then
  echo "usage: $0 [--site <pattern>|--no-site] '<mutation command>' <check command...>" >&2
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
# ⚠️ **선언한 자리를 실제로 쳤는가** — 착지(파일이 바뀜)와 의미(의도한 것이 됨)는 다르다.
# 여기서 거부하지 않으면, 다른 것이 된 변이가 엉뚱한 단언에 걸려 `CAUGHT` 으로 기록된다.
if [ "$SITE_MODE" = declared ]; then
  # ⚠️ **추가/삭제된 줄만 본다.** 문맥 줄까지 보면 「근처에 있었다」가 「쳤다」로 통과한다 —
  # 실측(이 커밋을 만들다가): 선언 패턴이 diff 문맥에 있어 거짓 통과했다. `+++`/`---` 헤더는 뺀다.
  # ⚠️ `|| true` 를 빼지 말 것 — 새 파일만 만든 변이면 diff 가 비어 grep 이 1 을 내고, `set -e` 가
  # 러너를 **판정 없이 종료코드 1(SILENT 의 코드)** 로 죽인다(실측 2026-09-26, `test-probe.sh`).
  _diff="$( (cd "$WT" && git diff -- .) | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)"
  # 신규 파일은 diff 에 안 나오므로 본문을 더한다(그래야 「새 파일에 심는 변이」도 선언할 수 있다).
  # ⚠️ 줄 단위로 읽는다 — `for … in $(…)` 는 이름의 공백에서 쪼개 본문을 못 읽고 자리가 없다며 INVALID 로
  # 갔다(실측 2026-09-26, Grok 레그의 퍼저).
  _newbody="$( (cd "$WT" && git ls-files --others --exclude-standard) 2>/dev/null \
    | while IFS= read -r _nf; do cat "$WT/$_nf" 2>/dev/null || true; echo; done)"
  _diff="$_diff
$_newbody"
  if ! printf '%s' "$_diff" | grep -qF -- "$SITE"; then
    fail_invalid "변이가 착지했지만 **선언한 자리를 담지 않는다**: [$SITE]
  변이는 파일을 바꿨으나 의도한 것이 되지 않았다(이스케이프·정규식·인터프리터를 의심하라).
  이 상태의 CAUGHT/SILENT 는 **다른 변이에 대한 답**이므로 판정하지 않는다."
  fi
  echo "선언한 자리 확인: [$SITE] ✓"
else
  echo "⚠️ --no-site — 변이가 의도한 것이 됐는지 **기계가 안 봤다**. 아래 diff 를 직접 읽어라."
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
  | while IFS= read -r _f; do printf '+++ (신규) %s\n' "$_f"; awk 'NR <= 20 { print "+" $0 }' "$WT/$_f" 2>/dev/null; done ) \
  | head -80 | sed 's/^/  /'

# ⚠️ **SILENT 를 선언하기 전에 「검사가 이 파일을 읽기는 하는가」를 본다.** 착지·의미에 이어
# 세 번째 사각이다 — 실측 2026-09-15: `DEPLOY_LANGS` 를 비우는 변이를
# `test-release-prerelease.sh` 로 검사해 **SILENT** 를 얻었는데, 그 파일은 `DEPLOY_LANGS` 를
# **아예 쓰지 않는다**(`deploy-facts` 언급 0건). 자리 검사는 통과했다 — 변이가 `deploy-facts.sh`
# 의 선언한 줄을 쳤으므로. 읽지 않는 것을 바꾼 뒤의 통과는 「가드가 침묵했다」가 아니라
# **아무 일도 없었다**이고, 그것을 구멍으로 쓰면 **없는 결함**을 보고하게 된다.
#
# ⚠️ **전이는 소싱(`.`/`source`)만 따라간다.** 처음엔 「파일명 언급」을 3단계 전이시켰는데,
# 가드 전부를 돌리는 워크플로 하나를 거쳐 **모든 파일이 서로 연결돼** 이 검사가 통째로 공허해졌다
# (실측: 같은 무관 변이가 그대로 SILENT 로 통과했다). 언급은 **씨앗 집합 안에서만** 본다.
# ⚠️ **동적으로 조립되는 경로는 이 근사가 못 본다**(`"$CONSUME/$1-run.sh"` 류). 그때는
# `--assume-relevant` 로 **명시적으로 면제**하라 — `--no-site` 와 같은 관용이다.
probe_relevant() {
  _rl_set=''
  for _a in "$@"; do
    [ -f "$WT/$_a" ] && _rl_set="$_rl_set $_a"
  done
  [ -n "$_rl_set" ] || return 1      # 씨앗조차 없다 = 파일을 하나도 안 읽는 검사
  # 소싱을 따라 닫는다(셸 스크립트가 실제로 읽는 것).
  _rl_i=0
  while [ "$_rl_i" -lt 5 ]; do
    _rl_new=''
    for _f in $_rl_set; do
      _rl_srcs="$(grep -oE '^[[:space:]]*(\.|source)[[:space:]]+"?[^"]*"?' "$WT/$_f" 2>/dev/null \
        | grep -oE '[A-Za-z0-9_.-]+[.](sh|bash)' | sort -u || true)"
      for _n in $_rl_srcs; do
        for _c in $( (cd "$WT" && git ls-files) | grep -E "(^|/)$_n\$" || true); do
          case " $_rl_set $_rl_new " in *" $_c "*) ;; *) _rl_new="$_rl_new $_c" ;; esac
        done
      done
    done
    [ -n "$_rl_new" ] || break
    _rl_set="$_rl_set $_rl_new"
    _rl_i=$((_rl_i + 1))
  done
  # 바뀐 파일이 그 집합에 있거나, 집합의 어느 파일이 그 **경로·파일명·디렉터리**를 문자열로
  # 언급하면 관련 있다(글롭으로 읽는 자리 — `.github/workflows/*.yml` 류 — 를 버리지 않기 위해).
  for _ch in $CHANGED; do
    case " $_rl_set " in *" $_ch "*) return 0 ;; esac
    _rl_base="$(basename "$_ch")"
    _rl_dir="$(dirname "$_ch")"
    for _f in $_rl_set; do
      grep -qF -- "$_rl_base" "$WT/$_f" 2>/dev/null && return 0
      [ "$_rl_dir" = "." ] && continue
      grep -qF -- "$_rl_dir" "$WT/$_f" 2>/dev/null && return 0
    done
  done
  return 1
}

# 판정.
# ⚠️ 검사 명령의 출력을 **버리지 않는다.** 「계측기가 죽은 것」과 「가드가 잡은 것」은 종료코드가
# 같다(실측: 가드 사본을 인자 없이 돌려 ENOENT 로 죽은 것을 `CAUGHT` 으로 읽었다). 잡혔다면
# **무엇이 잡았는지**가 화면에 있어야 한다.
_out="$(cd "$WT" && "$@" 2>&1)" && _rc=0 || _rc=$?
if [ "$_rc" = 0 ]; then
  if [ "$RELEVANCE_MODE" = waived ]; then
    echo "⚠️ --assume-relevant — 검사가 이 파일을 읽는지 **기계가 안 봤다**."
  elif ! probe_relevant "$@"; then
    fail_invalid "변이가 착지했고 자리도 맞지만, **검사 명령이 바뀐 파일을 읽지 않는다**.
  바뀐 파일: $(printf '%s' "$CHANGED" | tr '\n' ' ')
  검사 명령: $*
  읽지 않는 것을 바꾼 뒤의 통과는 '가드가 침묵했다'가 아니라 **아무 일도 없었다**이다 —
  이것을 SILENT 로 읽으면 **없는 구멍**을 보고하게 된다(실측 2026-09-15).
  경로가 런타임에 조립되면(변수로 만든 파일명 류) --assume-relevant 로 명시적으로 면제하라."
  fi
  echo "SILENT — 변이가 적용됐는데 검사 명령이 통과했다(진짜 구멍)."
  exit 1
fi
echo "CAUGHT — 검사 명령이 변이를 잡았다."
# ⚠️ **꼬리가 아니라 실패한 단언을 전부 찍는다.** `assert.sh` 는 fail-fast 가 아니라 누적하므로
# 한 변이가 여러 축을 동시에 넘어뜨린다. 꼬리만 보면 **물리적으로 마지막** 단언이 범인으로
# 기록된다 — 실측 2026-09-13: 새 단언이 파일 앞(132행)이고 마스킹 축이 뒤(563행)라 새 단언을
# **과소** 평가했고, 반대로 `test-deploy-facts.sh` 는 새 단언이 끝(280행)이라 앞(9행)이 잡은
# 것을 새 단언의 공으로 **과대** 평가했다. 위치 편향이 양방향으로 났다.
_fails="$(printf '%s\n' "$_out" | grep -aE '^FAIL |^::error::|^  *FAIL ' || true)"
if [ -n "$_fails" ]; then
  _nf="$(printf '%s\n' "$_fails" | grep -c . || true)"
  echo "실패한 단언 ${_nf}건:"
  printf '%s\n' "$_fails" | head -20 | sed 's/^/  /'
  [ "$_nf" -gt 20 ] && echo "  … 외 $((_nf - 20))건"
  # ⚠️ 둘 이상이면 **위치가 아니라 내용으로** 판정해야 한다 — 「의도한 단언이 그중에 있는가」다.
  if [ "$_nf" -gt 1 ]; then
    echo "  ⚠️ 실패 단언이 여럿이다 — 이 변이가 **의도한 단언**을 넘어뜨렸는지 위 목록에서 직접 확인하라."
    echo "     (한 축만 겨누려면 다른 축이 안 걸리는 격리 변이를 쓴다.)"
  fi
else
  echo "잡은 근거(검사 출력 끝 — 단언 형식이 아니다):"
  printf '%s\n' "$_out" | tail -12 | sed 's/^/  /'
fi
exit 0