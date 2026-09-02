#!/usr/bin/env sh
# 루트 README 두 개(영/한)의 배지가 (a) SSOT와 맞는가, (b) 서로 같은가, (c) **라이브 레지스트리
# 배지가 아닌가**.
#
# 왜 이 가드가 필요한가: 세 번째가 핵심이다. `CLAUDE.md`가 「라이브 레지스트리 배지는 여전히
# 금지」라고 적고 있는데 **그 규칙을 집행하는 것이 저장소에 하나도 없었다**(실측: `grep -rniE
# 'shields\.io|badge' scripts/` 히트 0). 레지스트리 배지는 아홉 레지스트리를 실시간으로 물어
# 문서가 버전 SSOT(`deploy-facts.sh`)를 우회하게 만든다 — 그리고 그건 **추가하는 순간에는
# 아무것도 깨뜨리지 않아** 리뷰에서 통과하기 쉽다.
#
# 나머지 배지 셋도 SSOT가 있는데 산문으로만 적혀 있었다: `languages-9`는 DEPLOY_LANGS 개수,
# `status-pre--1.0`은 게시 버전이 전부 0.x라는 사실, `Keycloak-26.6`은 호환성 문서의 서버 라인.
# 열 번째 언어가 들어오거나 첫 1.0이 나가는 순간 조용히 거짓이 된다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
set -- --lib
. "$ROOT/scripts/lib/deploy-facts.sh"

EN="$ROOT/README.md"
KO="$ROOT/README.ko.md"

# 마크다운 이미지 전부(배지는 전부 이 형태다).
badges() { grep -oE '!\[[^]]*\]\([^)]*\)' "$1" || true; }

# ---- 규칙 1: 라이브 레지스트리 배지 금지 (CLAUDE.md) ----
# shields.io의 레지스트리 엔드포인트는 `/<registry>/v/<pkg>` 꼴이다. 아홉 레지스트리를 전부 적는다 —
# ⚠️ `badge/` (정적)와 구분해야 한다. 정적 배지는 허용이고 레지스트리 조회만 금지다.
REGISTRY_RE='img\.shields\.io/(npm|pypi|crates|nuget|gem|packagist|maven-central|maven-metadata|hexpm|golang)/'
for f in "$EN" "$KO"; do
  b="$(basename "$f")"
  assert_eq "0" "$(badges "$f" | grep -cE "$REGISTRY_RE" || true)" \
    "$b: 라이브 레지스트리 배지 없음(버전 SSOT는 deploy-facts.sh다)"
done

# ---- 규칙 2: 영↔한 미러 ----
# README는 루트만 영한 미러이고 「동일 구조」가 규약이다. 배지가 한쪽에만 늘어나는 것이
# 가장 흔한 어긋남이라 집합으로 대조한다.
assert_eq "$(badges "$EN")" "$(badges "$KO")" "README 영/한의 배지 집합이 동일"

# ---- 규칙 3: languages-N == DEPLOY_LANGS 개수 ----
LANG_N="$(printf '%s\n' $DEPLOY_LANGS | grep -c . )"
for f in "$EN" "$KO"; do
  b="$(basename "$f")"
  got="$(badges "$f" | grep -oE 'badge/languages-[0-9]+' | grep -oE '[0-9]+$' | head -1)"
  assert_eq "$LANG_N" "${got:-없음}" "$b: languages 배지가 DEPLOY_LANGS 개수와 일치"
done

# ---- 규칙 3b: published-N/M 배지가 실제 게시 현황과 일치 ----
# ⚠️ 이 배지는 **개수를 말하므로** SSOT 파생이라야 한다. 열 번째 언어가 들어오면 분모가
# 자동으로 어긋나고, 어떤 언어의 게시가 빠지면 분자가 어긋난다 — 양쪽이 동시에 요구된다.
PUB_N=0
for L in $DEPLOY_LANGS; do
  [ -n "$(df_published_version "$L" 2>/dev/null || true)" ] && PUB_N=$((PUB_N + 1))
done
for f in "$EN" "$KO"; do
  b="$(basename "$f")"
  got="$(badges "$f" | grep -oE 'badge/published-[0-9]+%2F[0-9]+' | sed 's|.*published-||;s|%2F|/|' | head -1)"
  assert_eq "$PUB_N/$LANG_N" "${got:-없음}" "$b: published 배지가 실제 게시 개수/언어 수와 일치"
done

# ---- 규칙 4: status 배지 ↔ 게시 SSOT ----
#
# ⚠️ 이 규칙은 오래 **부정형 한 쪽만** 봤다 — 「`status-pre--1.0` 이 있으면 안 된다」. 그래서
# 1.0 이 나가고 배지가 `status-1.0` 으로 바뀐 순간 **아무것도 안 겨누게 됐다**(변이 실측:
# 두 README 에서 배지 줄을 통째로 지워도 전 가드 통과, `status-0.9` 로 값을 바꿔도 통과.
# 영/한 미러(규칙 2)가 한쪽만 지웠을 때 우는 것이 전부였다 — 자기일치는 둘 다 틀린 경우를
# 통과시킨다). 양성 어서션으로 뒤집는다.
#
# 배지가 말하는 것은 **바닥**이다("아홉이 전부 이 선 위에 있다"). 그래서 기대값은 게시된
# 버전들의 **최소 major.minor** 이고, 한 언어가 1.1 로 앞서가도 배지는 1.0 으로 남는 것이 옳다.
# 값을 여기 박지 않는다 — `df_published_version` 이 소유한다.
STABLE=0
MIN_MM=""
for L in $DEPLOY_LANGS; do
  v="$(df_published_version "$L" 2>/dev/null || true)"
  [ -n "$v" ] || continue
  case "$v" in 0.*) : ;; *) STABLE=$((STABLE + 1)) ;; esac
  _mm="$(printf '%s' "$v" | cut -d. -f1,2)"
  if [ -z "$MIN_MM" ]; then
    MIN_MM="$_mm"
  else
    # ⚠️ 문자열 비교가 아니라 수치 비교다 — 사전식이면 `1.10` 이 `1.9` 보다 작다고 나온다.
    _c1="${MIN_MM%%.*}"; _c2="${MIN_MM#*.}"
    _n1="${_mm%%.*}";    _n2="${_mm#*.}"
    if [ "$_n1" -lt "$_c1" ] || { [ "$_n1" -eq "$_c1" ] && [ "$_n2" -lt "$_c2" ]; }; then MIN_MM="$_mm"; fi
  fi
done
for f in "$EN" "$KO"; do
  b="$(basename "$f")"
  has_pre="$(badges "$f" | grep -c 'badge/status-pre--1\.0' || true)"
  if [ "$STABLE" -eq 0 ]; then
    assert_eq "1" "$has_pre" "$b: 게시 버전이 전부 0.x 이므로 pre-1.0 배지가 있어야 한다"
  else
    assert_eq "0" "$has_pre" "$b: 1.0 이상이 $STABLE 개 있으므로 pre-1.0 배지는 거짓이다"
    # ⚠️ 공허성 — 추출이 0건이면 `없음` 으로 떨어져 실패한다. 배지를 **지우는** 변이가
    # 이 한 줄로 잡힌다(값 변조는 기대값 불일치로 잡힌다).
    got="$(badges "$f" | grep -oE 'badge/status-[0-9]+\.[0-9]+-' | sed 's|.*badge/status-||;s|-$||' | head -1)"
    assert_eq "$MIN_MM" "${got:-없음}" \
      "$b: status 배지가 게시 SSOT 의 최소 major.minor 와 다르다 — 배지는 아홉의 바닥을 말한다"
  fi
done

# ---- 규칙 5: Keycloak 배지의 서버 라인이 호환성 문서와 일치 ----
# 호환성 문서가 그 값의 소유자다(각 릴리스가 실제로 어떤 서버 범위로 나갔는가).
COMPAT="$ROOT/docs/reference/compatibility.md"
assert_ok test -f "$COMPAT"
KC_DOC="$(grep -oE '26\.[0-9]+\.x' "$COMPAT" | head -1 | sed 's/\.x$//')"
assert_ok test -n "$KC_DOC"
for f in "$EN" "$KO"; do
  b="$(basename "$f")"
  got="$(badges "$f" | grep -oE 'badge/Keycloak-[0-9]+\.[0-9]+' | sed 's|.*Keycloak-||' | head -1)"
  assert_eq "$KC_DOC" "${got:-없음}" "$b: Keycloak 배지가 호환성 문서의 서버 라인과 일치"
done

# ---- 규칙 6: license 배지가 LICENSE 파일과 일치 ----
assert_ok test -f "$ROOT/LICENSE"
assert_ok grep -q "Apache License" "$ROOT/LICENSE"
for f in "$EN" "$KO"; do
  b="$(basename "$f")"
  assert_eq "1" "$(badges "$f" | grep -c 'badge/license-Apache--2\.0' || true)" \
    "$b: license 배지가 LICENSE(Apache-2.0)와 일치"
done

# ---- 대조군: 이 가드가 실제로 잡는가 ----
# ⚠️ 없으면 "전부 통과"가 검사가 도는 증거인지 정규식이 항상 거짓인지 구분할 수 없다.
# 위 정규식들에 실제 위반 문자열을 직접 먹여 반응을 본다.
assert_ok   sh -c 'printf "%s" "![npm](https://img.shields.io/npm/v/@xzawed/keycloak-sdk)" | grep -qE "img\.shields\.io/(npm|pypi|crates|nuget|gem|packagist|maven-central|maven-metadata|hexpm|golang)/"'
assert_fails sh -c 'printf "%s" "![License](https://img.shields.io/badge/license-Apache--2.0-blue)" | grep -qE "img\.shields\.io/(npm|pypi|crates|nuget|gem|packagist|maven-central|maven-metadata|hexpm|golang)/"'
# languages 추출이 숫자를 실제로 집는가(정규식이 비면 위 어서션이 "없음"으로 늘 실패하는 대신
# 조용히 통과하는 판을 막는다).
assert_eq "9" "$(printf '%s' '![Languages](https://img.shields.io/badge/languages-9-brightgreen)' | grep -oE 'badge/languages-[0-9]+' | grep -oE '[0-9]+$')"
# pre-1.0 판정이 버전 문자열에 실제로 반응하는가.
assert_eq "1" "$(printf '%s\n' '1.0.0' | grep -cvE '^0\.')"
assert_eq "0" "$(printf '%s\n' '0.2.0' | grep -cvE '^0\.')"

assert_report
