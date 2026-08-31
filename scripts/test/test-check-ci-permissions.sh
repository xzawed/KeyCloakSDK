#!/usr/bin/env sh
# CI 권한 가드 자가테스트 — 가드가 **실제로 위반을 잡는지**, 그리고 **잡으면 안 되는 것을
# 잡지는 않는지**(오탐)를 둘 다 확인한다. 통과만 확인하는 자가테스트는 공허하다: 아무것도
# 검사하지 않는 가드도 통과하기 때문이다.
#
# 각 변이는 규칙 하나에 대응한다. 가드에서 그 규칙 한 줄을 지우면 대응하는 변이가 빨개져야
# 한다(변이 검증). 그리고 종료코드만 보면 "다른 이유로 실패"해도 통과하므로, 핵심 변이는
# ::error:: 문구까지 고정한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/ci-permissions"
GUARD="$DIR/../check-ci-permissions.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# 변이마다 TMP를 비우고 다시 복사한다 — 변이 중 하나는 파일을 지우고 하나는 디렉터리를
# 통째로 비우므로, 덮어쓰기만으로는 앞 변이의 잔재가 남는다.

# ── 오탐 대조군 1: 정상 픽스처는 통과해야 한다 ──
# 여기에는 워크플로 레벨 권한만 가진 비-릴리스 워크플로(demo-ci.yml)가 함께 들어 있다.
# 릴리스 전용 규칙이 저장소 전체로 새면 이 단언이 먼저 깨진다.
cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# 인벤토리를 문자열로 고정한다. 종료코드만 보면 가드가 **아무 잡도 찾지 못한 채** 통과해도
# 알 수 없다(빈 집합에는 모든 규칙이 성립한다). 이 한 줄이 잡 발견·릴리스 분류·권한 상승
# 계수를 동시에 고정한다 — 특히 write 계수는 주석 제거(`write # 이유` → `write`)가 살아
# 있어야만 1이 나온다. 주석을 안 걷어내면 값이 "write # ..."가 되어 상승이 보이지 않는다.
out=$(node "$GUARD" "$TMP" 2>&1)
assert_contains "$out" "릴리스 1개 · 잡 8개 · 릴리스 잡의 write 상승 1건" "잡·릴리스·권한상승을 실제로 센다"

# ── 변이 1(규칙 1): 릴리스 잡에서 permissions 선언을 지운다 ──
# 이것이 이 가드를 만든 이유다. 릴리스 워크플로에는 워크플로 레벨 기본값이 없으므로
# 빠뜨린 잡은 **저장소 기본 권한**(Settings → Actions)을 물려받는다 — 이 저장소 바깥에서
# 바뀌는 값이고, PR 리뷰를 거치지 않는다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i '/^    permissions: {}$/d' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "잡 \`version\`에 \`permissions:\`가 없다" "권한 선언이 빠진 잡을 이름까지 짚어 잡는다"

# ── 변이 2(규칙 2): 릴리스 워크플로에 워크플로 레벨 permissions 블록을 되돌린다 ──
# S7637이 지적한 바로 그 형태다. 이 블록이 돌아오면 체크아웃도 안 하는 version 잡까지
# contents: read를 쥔다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|^jobs:|permissions:\n  contents: read\njobs:|' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "워크플로 레벨 \`permissions:\` 블록이 있다" "릴리스 워크플로의 워크플로 레벨 블록을 잡는다"

# ── 변이 3(규칙 3): 비-릴리스 워크플로에서 워크플로 레벨 권한을 통째로 지운다 ──
# 그러면 그 잡은 아무 데도 선언이 없어 저장소 기본 권한을 물려받는다. 규칙 1이 릴리스
# 전용이라 이 규칙이 없으면 새 워크플로를 권한 없이 추가하는 사고가 그대로 통과한다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i '/^permissions:$/,+1d' "$TMP/.github/workflows/demo-ci.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "저장소 기본 권한" "선언이 어디에도 없는 잡을 잡는다"

# ── 변이 4(규칙 4): 일괄 부여 ──
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|permissions: {}|permissions: write-all|' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "일괄 부여는 쓰지 않는다" "write-all을 잡는다"

# ── 변이 5(규칙 5): 권한 상승에서 근거 주석을 떼어낸다 ──
# ⚠️ 이 규칙이 증명하는 것은 "이유가 적혀 있다"이지 "그 이유가 참이다"가 아니다.
# 값은 `read` → `write` 한 단어짜리 조용한 diff를 불가능하게 만드는 데 있다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|      id-token: write #.*|      id-token: write|' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "근거 주석이 없다" "근거 없는 권한 상승을 잡는다"

# ── 오탐 대조군 2: 근거 주석은 스코프 줄 위에 있어도 인정한다 ──
# 표기 스타일로 사람과 싸우는 가드는 우회당한다. 꼬리 주석만 인정하면 아주 자연스러운
# 이 작성법이 오탐이 된다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|      id-token: write #.*|      # OIDC Trusted Publishing에 필요\n      id-token: write|' \
  "$TMP/.github/workflows/demo-release.yml"
assert_ok node "$GUARD" "$TMP"

# ── 변이 6(범위 침묵): 릴리스 워크플로가 사라지면 통과가 아니라 실패다 ──
# glob으로 범위를 좁힌 가드는 대상이 0건이어도 초록불을 낸다. 파일 개명 한 번으로 가드가
# 아무것도 검사하지 않게 되는 것이 이 종류 가드의 전형적인 실패 방식이다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
rm "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "검사 범위가 조용히 비었을 수 있다" "릴리스 워크플로 0건을 통과로 취급하지 않는다"

# --min-release는 실측 하한을 강제한다(CI가 이 방식으로 쓴다).
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP" --min-release=1
assert_fails node "$GUARD" "$TMP" --min-release=2

# ── 변이 7(fail-closed): 해석하지 못하는 모양은 통과가 아니라 실패다 ──
# 스캐너가 못 읽는 구조(머지 키·플로우 스타일 잡 본문)를 조용히 넘기면 그게 곧 우회로다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|^  integration:|  integration:\n    <<: *defaults|' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "fail-closed" "판단 불가(머지 키)를 통과로 처리하지 않는다"

# ⚠️ 아래 두 케이스는 반드시 문구까지 봐야 한다. `jobs:`를 주석 처리하면 "jobs 미발견"과
# "잡을 하나도 읽지 못했다"가 **둘 다** 실패로 이어지므로, 종료코드만 보는 단언은 앞 분기를
# 통째로 지워도 초록이다(변이 검증에서 실제로 걸렸다).
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|^jobs:|# jobs:|' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "최상위 \`jobs:\`를 찾지 못했다" "jobs 미발견을 통과로 취급하지 않는다"

# 플로우 스타일 잡 본문은 이 스캐너가 읽지 못한다 — 판단 불가는 통과가 아니다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
printf 'name: flow-release\non:\n  push:\njobs: {}\n' > "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "잡을 하나도 읽지 못했다" "플로우 스타일 jobs를 통과로 취급하지 않는다"

# 워크플로 디렉터리 자체가 없으면 "검사할 게 없다"가 아니라 실패다.
rm -rf "$TMP"; mkdir -p "$TMP"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "를 읽지 못했다" "워크플로 디렉터리 부재를 통과로 취급하지 않는다"

# 디렉터리는 있는데 비어 있는 경우는 **다른 분기**다. 종료코드만 보면 --min-release 실패에
# 가려서 이 분기가 죽어도 알 수 없다 — 문구로 분기를 짚는다.
rm -rf "$TMP"; mkdir -p "$TMP/.github/workflows"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "워크플로가 하나도 없다" "빈 워크플로 디렉터리를 통과로 취급하지 않는다"

# ── 규칙 6: govulncheck를 도는 잡은 setup-go에 `check-latest: true`가 있어야 한다 ──
# 왜: `check-latest` 없이는 setup-go가 러너 툴캐시의 낡은 패치를 그대로 쓴다. stdlib 취약점은
# 패치 릴리스로 고쳐지므로 **감사 잡이 낡은 툴체인을 감사**하게 되고, 고쳐진 것을 못 고쳐졌다고
# 보고한다(2026-08-17 실측: security-audit가 go1.26.5로 5건, 같은 커밋을 1.26.6으로 재검사하면
# `No vulnerabilities found.`).
# ⚠️ **빌드/테스트 잡에는 요구하지 않는다** — 그쪽은 소비자 하한을 재현해야 하므로 캐시를 그대로
# 쓴다. 이건 go-ci.yml이 선언한 정책이고 가드가 그 경계를 넘으면 안 된다(아래 대조군이 고정).
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's/^          check-latest: true$//' "$TMP/.github/workflows/demo-ci.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "check-latest: true" "govulncheck 잡의 check-latest 누락을 지목한다"
assert_contains "$out" "audit" "어느 잡인지 이름으로 짚는다"

# 대조군 — govulncheck를 돌지 않는 잡의 setup-go에는 요구하지 않는다. 없으면 "모든 setup-go에
# check-latest를 요구"하는 전혀 다른(그리고 소비자 하한 재현을 깨는) 가드가 된 것을 알 수 없다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# ── 규칙 7: govulncheck 버전 핀은 워크플로 간에 같아야 한다 ──
# 같은 두 파일이 지고 있는 **두 번째** 주석뿐인 동기화 약속이다
# (security-audit.yml: "⚠️ go-ci.yml의 버전과 함께 올린다"). 첫 번째(check-latest)가 이미
# 한쪽만 고쳐진 채 굳었으므로 이쪽도 기계로 잡는다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|govulncheck@v1\.6\.0|govulncheck@v1.7.0|' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "govulncheck 버전 핀이 워크플로마다 다르다" "한쪽만 올린 버전 핀을 지목한다"

# ── 규칙 8: 배포 시크릿을 env로 받는 잡은 그 env마다 빈값 검사를 가져야 한다 ──
# 아홉 레인 중 rust 하나가 이 가드 없이 굳어 있었다(2026-08-31). 미설정이 "스킵"이 되면
# 아무것도 게시하지 않은 실행이 성공한 실행과 구분되지 않는다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|^          if \[ -z "\$DEMO_TOKEN" \]; then$|          if false; then|' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "DEMO_TOKEN" "빈값 검사가 사라진 시크릿을 이름으로 지목한다"
# ⚠️ **주석을 가드로 세지 않는지가 이 규칙의 핵심이다.** 픽스처는 망가뜨린 뒤에도 「미설정」을
# 담은 주석과 `::error::DEMO_TOKEN 미설정` 문자열을 그대로 갖고 있다 — 실제 rust-release.yml 이
# 정확히 그 상태(설명 주석만 있고 실행되는 검사는 없음)였으므로, 문자열을 찾는 규칙이었다면
# 이 어서션이 초록으로 통과해 버린다. 그 위장이 살아 있음을 여기서 단언한다.
assert_contains "$(cat "$TMP/.github/workflows/demo-release.yml")" "미설정" \
  "망가뜨린 픽스처에 「미설정」 문자열이 남아 있어야 위장 대조군이 성립한다"

# 대조군 — 이름을 바꿔 받는 시크릿(`RENAMED` ← `DEMO_RENAMED_SECRET`)과 시크릿 없는 OIDC 잡은
# 요구 대상이 아니거나 이미 만족한다. 셋이 실제로 이름을 바꿔 받으므로(dispatch 의 `APP_ID`,
# kotlin 의 `ORG_GRADLE_PROJECT_*`) 시크릿 이름으로 걸면 오탐이 난다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"

# ── 오탐 대조군 3: 저장소 루트 실물에 대해 통과해야 한다 ──
# 픽스처에서만 도는 가드는 실제 트리와 어긋난 채로 초록불을 유지할 수 있다.
assert_ok node "$GUARD" "$DIR/../.."

assert_report
