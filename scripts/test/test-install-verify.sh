#!/usr/bin/env bash
# `harness/install/lib/verify-lib.sh`의 자가테스트 — 계획서 Task B4.
#
# 왜 이 테스트가 필요한가: 이 로직은 1000줄짜리 Docker 오케스트레이터 안에 있어서, **레그를
# 통째로 돌리기 전에는 시험할 방법이 없었다**. 그런데 바로 여기서 사고가 났다 —
# `ver_for_lang`의 폴백이 루프가 덮어쓰는 전역을 읽어 **직전 언어의 버전이 다음 언어로 샜다**.
# 기본 순서에서는 go가 첫 번째라 안 물렸고, 그래서 **야간 실행은 초록이었다**. 언어를
# 부분집합으로 돌릴 때만 나타나는 순서 의존성이었다(2026-08-11 실측).
#
# ⚠️ **bash로 돌린다**(다른 셸 가드는 dash 호환이지만 이것은 예외). 대상이 bash 스크립트이고
# 연관배열 `MANIFEST_VER`를 읽기 때문이다 — dash로는 애초에 소싱되지 않는다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$DIR/../.."
LIB="$ROOT/harness/install/lib/verify-lib.sh"

assert_ok test -f "$LIB"
# shellcheck source=/dev/null
. "$LIB"

# ---------------------------------------------------------------------------
# 1) 순서 의존성 회귀 — 이 테스트가 존재하는 이유
# ---------------------------------------------------------------------------
#
# 실제 사고를 그대로 재현한다: `./install-verify.sh java kotlin ruby php go`.
# 언어 루프는 매 반복에서 `PKG_VER="$(ver_for_lang "$L")"`로 전역을 덮어쓴다. 폴백이 그
# `$PKG_VER`를 읽으면 ruby(0.1.0.rc1) 다음의 php가 0.1.0.rc1을 받고, go는 `go/v0.1.0.rc1`이
# 유효한 Go semver가 아니라 publish에서 죽는다. 폴백이 `$PKG_VER_DEFAULT`를 읽어야 한다.
PKG_VER_EXPLICIT=0
PKG_VER_DEFAULT="0.1.0"
PKG_VER="$PKG_VER_DEFAULT"
declare -A MANIFEST_VER=(
  [python]="0.1.0rc1" [node]="0.1.0-rc.2" [rust]="0.1.0-rc.1"
  [ruby]="0.1.0.rc1"  [kotlin]="0.1.0-RC1" [dotnet]="0.1.0"
)

iv_seq=""
for L in java kotlin ruby php go; do
  PKG_VER="$(ver_for_lang "$L")"    # 실제 루프와 **같은 전역 덮어쓰기**를 재현한다
  iv_seq="$iv_seq $L=$PKG_VER"
done
assert_eq " java=0.1.0 kotlin=0.1.0-RC1 ruby=0.1.0.rc1 php=0.1.0 go=0.1.0" "$iv_seq" \
  "부분집합 순서(java kotlin ruby php go)에서 직전 언어의 버전이 다음 언어로 샌다 — 폴백이 \$PKG_VER_DEFAULT가 아니라 \$PKG_VER를 읽나?"

# 대조군 — 기본 순서(go가 첫 번째)에서는 이 버그가 **안 보인다**. 그래서 야간이 초록이었다.
# 이 행이 없으면 위 어서션이 "원래 순서 무관하게 통과하는 것"과 구분되지 않는다.
PKG_VER="$PKG_VER_DEFAULT"
iv_seq2=""
for L in go php java; do
  PKG_VER="$(ver_for_lang "$L")"
  iv_seq2="$iv_seq2 $L=$PKG_VER"
done
assert_eq " go=0.1.0 php=0.1.0 java=0.1.0" "$iv_seq2" "기본 순서(대조군)에서도 폴백이 기본값이어야 한다"

# ---------------------------------------------------------------------------
# 2) `--version` 명시가 매니페스트보다 우선한다
# ---------------------------------------------------------------------------
#
# 사람이 손으로 버전을 지정하면 아홉 언어 **전부** 그 값으로 검증해야 한다 — 매니페스트 파생이
# 끼어들면 "내가 지정한 것과 다른 것을 검증했다"가 된다.
PKG_VER_EXPLICIT=1
PKG_VER="9.9.9"
for L in python node rust ruby kotlin dotnet go php java; do
  assert_eq "9.9.9" "$(ver_for_lang "$L")" "--version 명시 시 $L 이 매니페스트 값을 쓴다"
done
PKG_VER_EXPLICIT=0
PKG_VER="$PKG_VER_DEFAULT"

# ---------------------------------------------------------------------------
# 3) 매니페스트가 산출물 버전을 정하는 여섯 언어는 그 값을 쓴다
# ---------------------------------------------------------------------------
#
# ⚠️ 이 여섯과 나머지 셋의 구분이 곧 "publish가 무엇을 만드는가"다. 여섯은 매니페스트가 산출물
# 이름을 정하므로 다른 버전을 기대하면 publish에서 반드시 죽는다. 셋(go·php는 태그 SSOT,
# java는 versions:set 주입)은 publish→consume이 자기완결이라 기본값으로 충분하다.
for L in python node rust ruby kotlin dotnet; do
  assert_eq "${MANIFEST_VER[$L]}" "$(ver_for_lang "$L")" "$L 은 매니페스트 파생 버전을 써야 한다"
done
for L in go php java; do
  assert_eq "$PKG_VER_DEFAULT" "$(ver_for_lang "$L")" "$L 은 기본값을 써야 한다(태그 SSOT·주입)"
done

# ⚠️ 매니페스트 값이 **비어 있으면** 폴백으로 내려가야 한다(파생 실패를 조용히 빈 버전으로
# 넘기면 컨테이너가 `@` 뒤에 아무것도 없는 좌표를 받는다).
MANIFEST_VER[rust]=""
assert_eq "$PKG_VER_DEFAULT" "$(ver_for_lang rust)" "매니페스트 값이 비면 기본값으로 폴백해야 한다"
MANIFEST_VER[rust]="0.1.0-rc.1"

# ---------------------------------------------------------------------------
# 4) 버전 형식 검증 — 이 값은 sed 표현식과 컨테이너 명령에 삽입된다
# ---------------------------------------------------------------------------
#
# ⚠️ **아홉 레지스트리의 표기를 전부 받아야 한다.** 하나라도 거부하면 그 언어를 검증할 수 없다.
for v in 0.1.0 0.1.0rc1 0.1.0-rc.1 0.1.0.rc1 0.1.0-RC1 0.1.0-SNAPSHOT 1.2.3+build; do
  assert_ok validate_pkg_ver "$v" "허용표기"
done
# ⚠️ 거부해야 하는 것 — 셸 메타문자·경로탈출·옵션처럼 보이는 값·X.Y.Z가 아닌 값.
for v in '0.1.0; rm -rf /' '0.1.0$(id)' '0.1.0`id`' '../../etc' '-rf' '0.1.0/../x' 'latest' '1.2' '' ; do
  assert_fails validate_pkg_ver "$v" "거부표기"
done

assert_report
