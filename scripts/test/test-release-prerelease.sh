#!/usr/bin/env sh
# 릴리스 프리릴리스 판정 자가테스트.
#
# 왜 이 파일이 있는가: `php-v0.1.0-rc.1`의 첫 실행에서 파이프라인 다섯 잡이 전부 green이었는데도
# GitHub Release가 `prerelease=false`로 만들어져 RC가 저장소의 **Latest release**로 걸렸다.
# 파이프라인 성공은 이 결함을 잡지 못한다 — 태그를 태우지 않고 검증할 수 있는 것은 **판정 로직**뿐이다.
#
# 그래서 이 테스트는 워크플로에서 판정 블록을 **그대로 떼어내** 실행한다. 복사본을 두고 테스트하면
# 워크플로만 고쳤을 때 조용히 통과한다 — 검증 대상은 실제로 배포되는 그 문자열이어야 한다.
#
# 검사하는 것:
#   (1) `gh release create`를 부르는 워크플로 집합 == 판정 블록을 가진 워크플로 집합 (양방향)
#   (2) 세 블록이 글자 그대로 동일 (한 곳만 고치는 드리프트 차단)
#   (3) 판정 결과가 `--prerelease=`로 실제 배선됨 (판정만 하고 안 쓰는 사고 차단)
#   (4) 분류표 — 아홉 언어의 표기 + 오탐 대조군
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
WF="$(cd "$DIR/../.." && pwd)/.github/workflows"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 마커 사이만 뽑고 워크플로 들여쓰기(`run: |` 안 10칸)를 벗긴다. `{10}` 반복 표기는 mawk에서
# 기본 비활성이라 리터럴 공백 10칸으로 적는다(ubuntu 러너의 기본 awk가 mawk다).
#
# ⚠️ `\r`도 떼어낸다. `.gitattributes`는 `*.sh`·`*.md`만 `eol=lf`로 고정하고 `*.yml`은 고정하지
# 않으므로 Windows 기본(`core.autocrlf=true`) 체크아웃에서 워크플로는 **CRLF**로 내려온다.
# 그러면 떼어낸 블록이 `Syntax error: word unexpected (expecting "in")`으로 죽어(실측: Alpine
# dash) 이 테스트는 CI에서만 돌릴 수 있는 것이 됐다 — 로컬에서 검증할 수 없는 가드는 로컬에서
# 회귀를 잡지 못한다.
extract() {
  awk '
    /# <<< prerelease-classify/ { inb = 0 }
    inb                         { sub(/\r$/, ""); sub(/^          /, ""); print }
    /# >>> prerelease-classify/ { inb = 1 }
  ' "$1"
}

# ── (1) 호출자 집합 == 블록 보유자 집합 ────────────────────────────────────────
# 한 방향만 보면 새 릴리스 워크플로가 판정 없이 추가돼도 통과한다. 반대 방향은 블록만 남고
# 호출부가 사라진(= 죽은 코드) 상태를 잡는다. 두 목록을 문자열로 고정하면 둘 다 걸린다.
# 패턴에 여는 따옴표를 포함한다 — 이 워크플로들의 `permissions:` 근거 주석이 `` `gh release create` ``를
# 그대로 인용하고 있어서, 따옴표 없이 grep하면 호출부와 주석을 구분하지 못한다.
callers="$(grep -rl 'gh release create "' "$WF" | sort)"
marked="$(grep -rl '>>> prerelease-classify' "$WF" | sort)"
assert_eq "$callers" "$marked" "GitHub Release를 만드는 워크플로와 프리릴리스 판정을 가진 워크플로가 정확히 같은 집합이다"
assert_eq "3" "$(printf '%s\n' "$callers" | wc -l | tr -d ' ')" "Release를 만드는 워크플로는 셋(go·dotnet·php)이다"

# ── (2) 세 블록이 글자 그대로 동일 ────────────────────────────────────────────
first=''
for f in $callers; do
  base="$(basename "$f")"
  extract "$f" >"$TMP/$base.block"
  assert_ok test -s "$TMP/$base.block"
  if [ -z "$first" ]; then
    first="$TMP/$base.block"
  else
    # 메시지 없는 assert_ok 는 실패해도 어느 워크플로가 갈라졌는지 안 말한다
    # (실측 2026-09-15: 실제 갈라짐 변이가 낸 것은 tmp 경로 두 줄뿐이었다).
    _rp_same=0; cmp -s "$first" "$TMP/$base.block" || _rp_same=1
    assert_eq "ok" "$(ok_if "$_rp_same" DIFFERS)" \
      "$base 의 판정 블록이 다른 워크플로와 글자 그대로 같지 않다 — 셋이 함께 움직여야 하는 계약이다"
  fi
done
cp "$first" "$TMP/classify.sh"
# 블록이 실제로 판정을 **한다**는 것도 고정한다 — 마커만 남기고 본문을 지워도 (1)(2)는 통과한다.
assert_contains "$(cat "$TMP/classify.sh")" 'PRERELEASE=true' "블록이 판정 본문을 담고 있다"
assert_contains "$(cat "$TMP/classify.sh")" 'CORE="${VERSION%%+*}"' "블록이 빌드 메타데이터를 떼어낸다(오탐 방지선)"

# ── (3) 판정이 gh로 배선됐는가 ────────────────────────────────────────────────
# 판정만 하고 `gh release create`에 안 넘기면 버그는 그대로다. 세 파일 각각에서 확인한다.
#
# ⚠️ **파일 어딘가에 플래그가 있다」로 보면 안 된다.** 예전에는 그랬고, 변이 프로브가 그것을
# 잡아냈다(실측 2026-09-10 `SILENT`): `gh release create` 줄에서 플래그를 떼고 그 문자열을
# **주석에 남기기만** 해도 통과했다. 그러면 RC 가 Latest 로 나간다 — `php-v0.1.0-rc.1` 에서
# 실제로 일어난 그 사고다.
#
# 그래서 **그 명령 하나**를 연속행까지 이어 붙여 뽑고 거기서 찾는다. 세 모양이 다르지만 수렴한다
# (실측: `run:` 한 줄 · 백슬래시 연속행 · 인자만 한 줄 — 3/3, 오탐 0).
gh_create_cmd() { # $1=워크플로 파일 → `gh release create "` 명령 한 줄(연속행 이어붙임)
  awk '
    /^[[:space:]]*#/ { next }                        # 셸 주석 줄은 명령이 아니다
    !p && !/gh release create "/ { next }
    { p = 1; line = $0; sub(/[[:space:]]+$/, "", line)
      if (substr(line, length(line)) == "\\") { acc = acc substr(line, 1, length(line) - 1) " "; next }
      acc = acc line; print acc; exit }
  ' "$1"
}
for f in $callers; do
  base="$(basename "$f")"
  assert_contains "$(cat "$f")" 'prerelease: ${{ steps.derive.outputs.prerelease }}' "$base: version 잡이 판정을 출력한다"
  assert_contains "$(cat "$f")" 'PRERELEASE: ${{ needs.version.outputs.prerelease }}' "$base: 릴리스 잡이 그 출력을 받는다"
  _cmd="$(gh_create_cmd "$f")"
  assert_ok test -n "$_cmd"   # 공허 방지: 명령을 못 뽑으면 아래 검사가 무의미하다
  assert_contains "$_cmd" '--prerelease="${PRERELEASE}"' \
    "$base: gh release create **명령 자체**에 플래그가 없다 — 주석에만 남기면 RC 가 Latest 로 나간다"
done


# ⚠️ **두 추출기가 인자를 실제로 읽는가.** 위 공허 방지선은 **비었는지**만 본다
# (`test -s` · `test -n "$_cmd"`) — 실측(2026-09-15, `scripts/probe.sh --site`):
#   · `gh_create_cmd` 를 **플래그가 든 고정 문자열**로 바꾸니 **SILENT**
#   · `extract` 가 인자를 무시하고 **한 파일만** 읽게 하니 **SILENT**
#     (그러면 세 블록이 구조적으로 같아져 `cmp -s` 가 무의미해진다 — dotnet·php 블록이
#      갈라져도 안 보인다)
# ⚠️ **다만 「가드가 실물을 못 잡는다」는 아니다** — 같은 러너로 잰 실측: dotnet 블록을 실제로
# 갈라놓으면 **CAUGHT**, php 명령에서 플래그를 떼면 **CAUGHT**. 공허는 **가드 자신을 고칠 때만**
# 열린다. 그래서 대조군은 **그 추출기 자신**을 결함 사본에 태워 결함이 **보이는지** 본다.
rp_extract_control() {
  _rpe_tmp="$(mktemp -d)"
  _rpe_src="$(printf '%s\n' $callers | head -1)"
  # 블록 안에 표식 한 줄을 넣은 사본. 추출이 인자를 읽으면 그 표식이 결과에 나와야 한다.
  awk '{ print } /# >>> prerelease-classify/ { print "          # CONTROL-MARK" }' \
    "$_rpe_src" > "$_rpe_tmp/w.yml"
  _rpe_hit=1
  extract "$_rpe_tmp/w.yml" | grep -q 'CONTROL-MARK' && _rpe_hit=0
  # 양성 — 표식이 없는 사본에서는 안 나와야 한다(「늘 참」과 구분).
  cp "$_rpe_src" "$_rpe_tmp/clean.yml"
  _rpe_clean=0
  extract "$_rpe_tmp/clean.yml" | grep -q 'CONTROL-MARK' && _rpe_clean=1
  rm -rf "$_rpe_tmp"
  assert_eq "ok" "$(ok_if "$_rpe_hit" NOT-SEEN)" \
    "[음성대조·블록추출] 블록에 표식을 넣은 사본에서도 추출이 그것을 못 봤다 — extract 가 인자를 안 읽거나 센티널이 낡았다"
  assert_eq "ok" "$(ok_if "$_rpe_clean" SEEN)" \
    "[양성대조·블록추출] 표식이 없는 사본에서 표식을 봤다 — 추출이 인자와 무관한 값을 낸다"
}
rp_ghcmd_control() {
  _rpg_tmp="$(mktemp -d)"
  _rpg_src="$(printf '%s\n' $callers | head -1)"
  # 명령에서 플래그만 떼어낸 사본. 추출이 인자를 읽으면 결과에 플래그가 없어야 한다.
  sed 's/--prerelease="${PRERELEASE}"/DROPPED-BY-CONTROL/' "$_rpg_src" > "$_rpg_tmp/w.yml"
  _rpg_cmd="$(gh_create_cmd "$_rpg_tmp/w.yml")"
  _rpg_gone=1
  case "$_rpg_cmd" in *'--prerelease='*) ;; *) _rpg_gone=0 ;; esac
  # 양성 — 손대지 않은 사본에서는 플래그가 그대로 보여야 한다.
  cp "$_rpg_src" "$_rpg_tmp/clean.yml"
  _rpg_kept=1
  case "$(gh_create_cmd "$_rpg_tmp/clean.yml")" in *'--prerelease='*) _rpg_kept=0 ;; esac
  rm -rf "$_rpg_tmp"
  assert_eq "ok" "$(ok_if "$_rpg_gone" STILL-THERE)" \
    "[음성대조·명령추출] 플래그를 뗀 사본에서도 추출 결과에 플래그가 있다 — gh_create_cmd 가 인자를 안 읽는다(고정 문자열)"
  assert_eq "ok" "$(ok_if "$_rpg_kept" NOT-SEEN)" \
    "[양성대조·명령추출] 손대지 않은 사본에서 플래그를 못 봤다 — 연속행 이어붙임이 낡았다"
}
rp_extract_control
rp_ghcmd_control

# ── (4) 분류표 ────────────────────────────────────────────────────────────────
# 워크플로에서 떼어낸 블록을 그대로 실행한다. 판정 불가는 exit 1이므로 UNDECIDABLE로 접는다.
# ⚠️ 블록의 출력은 **stdout으로** 버린다 — `::error::`는 GitHub 워크플로 명령이라 stderr가 아니라
# stdout으로 나간다(2>/dev/null만 걸면 진단 문구가 판정값에 섞여 들어온다).
# ⚠️ **classify 는 기대값을 볼 수 없어야 한다 — 서브셸이라 루프 변수를 상속한다.**
# 실측(2026-09-15, `scripts/probe.sh --site`): `printf '%s' "$PRERELEASE"` 를 `"$want"` 로
# 바꾸니 표가 **자기 자신과 대조**하게 돼 열다섯 행이 전부 통과했다(**SILENT**).
# 행수 하한(`rows == 15`)도 모두 돌기는 했으므로 잡지 못한다 — **공허한 것은 행수가
# 아니라 오라클이다**. 독립 레그(Grok)가 코드만 읽고 이 자리를 지목했고 프로브가 확인했다.
# 그래서 기대값을 담은 변수를 **비우고** 부른다 — 이제 `"$want"` 로 바꿔도 빈 문자열이 나온다.
classify() {
  (
    want=''; ROWS=''          # 오라클 결합 차단 — 기대값을 볼 수 없다
    VERSION="$1"
    . "$TMP/classify.sh" >/dev/null 2>&1
    printf '%s' "$PRERELEASE"
  ) || printf 'UNDECIDABLE'
}

# 왼쪽이 입력, 오른쪽이 기대값. 각 행이 지키는 것:
#   1.0.0+incompatible  — 빌드 메타데이터 제거선. 이 행 없이는 정식 go 버전이 프리릴리스로 샌다(오탐).
#   1.2.3.4             — NuGet 4마디. "숫자 마디 = 정식"이 3마디로 좁혀지면 여기서 걸린다.
#   1.0.0-1             — 알파벳 없는 SemVer 프리릴리스. 하이픈 규칙을 지우면 UNDECIDABLE이 된다.
#   0.1.0rc1/0.1.0.rc1  — PEP 440·RubyGems 표기. go/dotnet/php로는 올 수 없지만, 이 판정이
#                         python/ruby로 확장돼도 조용히 틀리지 않는다는 계약이다.
#   1.0.0_1             — 모르는 표기. fail-closed가 살아 있는지 본다(else를 false로 바꾸면 빨개진다).
ROWS='0.1.0=false
1.0.0=false
0.10.0=false
1.2.3.4=false
1.0.0+incompatible=false
0.1.0-rc.1=true
0.1.0-RC1=true
0.1.0rc1=true
0.1.0.rc1=true
0.1.0-SNAPSHOT=true
0.1.0-alpha.2=true
1.0.0-1=true
0.1.0-rc.1+build.7=true
1.0.0_1=UNDECIDABLE
=UNDECIDABLE'

printf '\n%-24s %-12s %s\n' 'VERSION' 'EXPECTED' 'ACTUAL'
rows=0
printf '%s\n' "$ROWS" | while IFS= read -r row; do
  v="${row%=*}"
  want="${row##*=}"
  got="$(classify "$v")"
  printf '%-24s %-12s %s\n' "${v:-(empty)}" "$want" "$got"
done
# 위 while은 파이프라인이라 서브셸에서 돌아 카운터가 새지 않는다 — 단언은 여기서 다시 돈다.
for row in $ROWS; do
  v="${row%=*}"
  want="${row##*=}"
  assert_eq "$want" "$(classify "$v")" "분류: '${v:-(empty)}'"
  rows=$((rows + 1))
done
# 표가 조용히 비면(변수명을 잘못 고치는 등) 위 루프는 0회 돌고 통과한다. 행수를 못박는다.
assert_eq "15" "$rows" "분류표 행수(줄이는 변경은 곧 커버리지 축소다)"

# ⚠️ **음성 대조군 — 오라클이 입력에 반응하는가.** 행수 하한은 **몇 번 돌았는지**만 센다 —
# 분류기가 입력과 무관하게 기대값을 되돌려도 그 수는 그대로다(실측 SILENT).
# 정식과 프리릴리스는 반드시 **다른** 답이 나와야 한다 — 같으면 분류가 아니다.
_rp_a="$(classify 1.0.0)"; _rp_b="$(classify 0.1.0-rc.1)"
_rp_disc=1; [ "$_rp_a" != "$_rp_b" ] && _rp_disc=0
assert_eq "ok" "$(ok_if "$_rp_disc" SAME)" \
  "[음성대조·분류기] 정식(1.0.0)과 프리릴리스(0.1.0-rc.1)에 **같은 답**을 낸다 — 분류기가 입력을 안 보거나 기대값을 되돌려준다"
_rp_ok=1; [ "$_rp_a" = "false" ] && _rp_ok=0
assert_eq "ok" "$(ok_if "$_rp_ok" "$_rp_a")" \
  "[양성대조·분류기] 정식 1.0.0 을 false 로 안 봄 — 분류 블록이나 실행 경로가 낛았다"

assert_report
