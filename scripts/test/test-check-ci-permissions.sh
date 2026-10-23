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
assert_contains "$out" "릴리스 1개 · 잡 11개 · 게시 잡 1개 · 비로컬 uses 5개 · 릴리스 잡의 write 상승 2건 · write+체크아웃 잡 1개 · PR 시크릿 잡 1개" "잡·릴리스·게시잡·uses·권한상승·write+체크아웃·PR 시크릿 잡을 실제로 센다"

# ── 변이 1b: 쓰기 토큰을 쥔 잡이 체크아웃 자격증명을 남긴다 ──
# ⚠️ **이 규칙은 오래 자가테스트가 전혀 덮지 않았다**(픽스처에 write+체크아웃 잡이 없었다).
# 실제 트리에서만 돌았고, 그래서 아래 두 구멍이 둘 다 실측으로 드러났다(2026-09-23).
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i '/^          persist-credentials: false$/d' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "attestations: write" "⚠️ `contents: write` 가 아닌 쓰기 스코프도 대상이다 — 실제 스코프 이름을 짚는다"
assert_contains "$out" "persist-credentials: false\` 가 없다" "자격증명을 남기는 쓰기 잡을 잡는다"

# ⚠️ **주석이 설정 행세를 하면 안 된다.** 실측: 이 규칙을 넓히면서 `release.yml` 에 경위 주석을
# 달았더니 그 **글자 때문에** 실제 설정 줄을 지워도 규칙이 침묵했다 — 가드를 무력화하는 데
# 필요한 것이 설정 변경이 아니라 주석 한 줄이었다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|^          persist-credentials: false$|          # persist-credentials: false 는 여기 있었다|' \
  "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "persist-credentials: false\` 가 없다" "주석 안의 같은 글자를 설정으로 세지 않는다"

# ⚠️ `id-token: write` 만 가진 잡은 **대상이 아니다**(거짓 양성 대조군). OIDC 토큰은 git
# 자격증명이 아니라 `ACTIONS_ID_TOKEN_REQUEST_*` 로 받으므로 남은 토큰이 그 능력을 주지 않는다.
# 이것이 없으면 규칙을 「쓰기면 전부」로 넓혀도 테스트가 통과한다(실측: 그렇게 넓혔더니
# node/python 릴리스 잡 둘이 거짓 양성으로 걸렸다).
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|^  publish:$|  publish:\n    # (아래 스텝에 체크아웃을 더해 id-token 전용 잡을 만든다)|' "$TMP/.github/workflows/demo-release.yml"
sed -i 's|^      - run: echo "픽스처 — 실행되지 않는다"$|      - uses: actions/checkout@0000000000000000000000000000000000000000 # 픽스처|' \
  "$TMP/.github/workflows/demo-release.yml"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_eq "" "$(printf '%s' "$out" | grep 'publish\`' | grep 'persist-credentials' || true)" \
  "id-token: write 만 가진 잡은 이 규칙의 대상이 아니다"

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

# ── 규칙 9: 게시 잡은 통합 E2E + install-smoke 뒤에만 돈다 ──
# CLAUDE.md 가 릴리스 불변식으로 선언하는데 `needs:` 를 읽는 자리가 없었다(실측 2026-09-02).
# ⚠️ 조준점이 게시 **명령**이 아니라 **잡 키**인 이유는 규칙 9 주석에 있다 — 명령으로 찾으면
# python(액션으로 게시)·go(`gh release create`)를 놓치고 dispatch-release 를 오탐한다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's/^    needs: \[version, integration, install-smoke\]$/    needs: [version]/' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "발행 전 E2E 게이트가 끊겼다" "게시 잡의 needs 강등을 지목한다"

# ── 규칙 10: 비로컬 액션은 40자 SHA 로 핀한다 ──
# 현재 트리는 완전했지만 그것을 지키는 것이 없었다 — `checkout@v7` 로 강등해도 통과했다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|actions/setup-go@0000000000000000000000000000000000000000|actions/setup-go@v6|' "$TMP/.github/workflows/demo-ci.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "40자 SHA 로 핀되지 않았다" "SHA 아닌 액션 ref 를 지목한다"

# ── 공허성: 조준점이 사라지면 하한이 운다 ──
# 규칙 9·10 은 발견 기반이라 잡 키 개명이나 `uses:` 표기 변경으로 조용히 0건이 될 수 있다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
assert_fails node "$GUARD" "$TMP" --min-publish=99
out=$(node "$GUARD" "$TMP" --min-publish=99 2>&1 || true)
assert_contains "$out" "규칙 9 가 조용히 비었을 수 있다" "게시 잡 하한이 공허를 막는다"
assert_fails node "$GUARD" "$TMP" --min-uses=999
out=$(node "$GUARD" "$TMP" --min-uses=999 2>&1 || true)
assert_contains "$out" "규칙 10 이 조용히 비었을 수 있다" "uses 하한이 공허를 막는다"

# ── 플로우 매핑 `permissions:` 는 통과가 아니라 오류다 ──
# 이 스캐너는 들여쓰기와 키만 읽으므로 `permissions: {contents: write}` 는 자식 노드를 만들지
# 않아 **스코프가 통째로 안 보인다.** 실측(수정 전): 근거 주석 없는 상승을 그 표기로 넣었더니
# 인벤토리의 상승 수가 6 → 5 로 **줄고** 가드는 통과했다. 파일 헤더는 이미 「해석하지 못하는
# 모양은 통과가 아니라 오류」라고 약속하고 있었는데 코드가 그것을 지키지 않았다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's|^    permissions:$|    permissions: {contents: write, id-token: write}|' "$TMP/.github/workflows/demo-release.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "플로우 매핑으로 적혀 있어" "플로우 표기를 fail-closed 로 지목한다"

# 대조군: `permissions: {}` 는 막지 않는다. 빈 매핑은 「권한 없음」이라 읽을 스코프가 없고,
# 네 릴리스 워크플로가 실제로 그 표기를 쓴다 — 여기서 막으면 즉시 전면 RED 다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
assert_ok node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_not_contains "$out" "플로우 매핑" "빈 매핑 {} 를 오탐하지 않는다"

# ── 공허성: 권한 상승 수에도 하한이 있다 ──
# 규칙 5 는 상승을 **발견해서** 검사하므로, 상승이 스캐너에 안 보이면 0건을 검사하고 초록을 낸다.
# 이 수는 오래 인쇄만 되고 아무도 보지 않았다.
assert_fails node "$GUARD" "$TMP" --min-escalations=99
out=$(node "$GUARD" "$TMP" --min-escalations=99 2>&1 || true)
assert_contains "$out" "규칙 5 가 상승을 못 보고 있을 수 있다" "상승 하한이 공허를 막는다"

# ── 규칙 11: PR 에서 시크릿을 쥐는 잡은 Dependabot 이 연 PR 에서 돌지 않는다 ──
# 실측: actor 로만 거르던 sonarcloud.yml 이 2026-10-08~21 일곱 번, 사람이 Dependabot PR 에 커밋을
# 얹은 실행에서 방금 bump 된 미검토 패키지와 SONAR_TOKEN 을 한 잡에서 돌렸다.
# 첫 변이가 그 원래 식이다. ⚠️ 이 식도 Dependabot 이 **트리거한** 실행은 건너뛴다 — 아래 부정 단언이
# 평가가 시나리오별로 실제로 갈리는지(「if: 가 있으면 무조건 실패」가 아닌지)를 고정한다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i "s/^    if: .*/    if: github.event_name != 'pull_request' || github.actor != 'dependabot[bot]'/" "$TMP/.github/workflows/demo-scan.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "사람이 커밋을 얹음" "actor 만 보는 건너뛰기를 그 시나리오 이름으로 잡는다"
assert_not_contains "$out" "Dependabot 이 갱신」" "Dependabot 이 트리거한 실행은 원래 식도 건너뛴다 — 평가가 시나리오별로 갈린다"

# `&&` 를 `||` 로 — 글자로는 작성자 검사가 있다. 문자열 대조였다면 통과했을 식이다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i "s/github.actor != 'dependabot\[bot\]' && /github.actor != 'dependabot[bot]' || /" "$TMP/.github/workflows/demo-scan.yml"
assert_contains "$(cat "$TMP/.github/workflows/demo-scan.yml")" "'dependabot[bot]' || github.event.pull_request" "변이가 실제로 착지했다"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "사람이 커밋을 얹음" "작성자 검사를 || 로 이은 식을 평가로 잡는다"

# `if:` 가 없으면 Dependabot PR 에서도 돈다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i '/^    if: /d' "$TMP/.github/workflows/demo-scan.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "\`if:\` 가 없다" "if 없는 시크릿 PR 잡을 잡는다"

# 건너뛰기가 push 로 새면 main 실행이 사라진다(PR0 fail-closed).
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i "s/^    if: .*/    if: github.event_name == 'pull_request' \&\& github.event.pull_request.user.login != 'dependabot[bot]'/" "$TMP/.github/workflows/demo-scan.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "push 실행까지 건너뛴다" "push 를 건너뛰는 식을 잡는다"

# pull_request_target 도 범위다 — 그 트리거는 기본 브랜치 맥락에서 돈다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's/^  pull_request:$/  pull_request_target:/' "$TMP/.github/workflows/demo-scan.yml"
sed -i "s/^    if: .*/    if: github.event_name != 'pull_request_target' || github.actor != 'dependabot[bot]'/" "$TMP/.github/workflows/demo-scan.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "(pull_request_target)에서 돈다" "pull_request_target 트리거도 평가한다"

# 워크플로 레벨 env 의 시크릿은 모든 잡이 쥔다 — 시크릿이 없던 lint 잡이 대상이 된다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i 's/^jobs:$/env:\n  WIDE: ${{ secrets.DEMO_WIDE }}\njobs:/' "$TMP/.github/workflows/demo-scan.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "잡 \`lint\` 은 PR 에서 \`DEMO_WIDE\` 를 쥐는데" "워크플로 레벨 시크릿을 모든 잡에 건다"

# ⚠️ 모르는 것은 통과가 아니라 오류다 — 모르는 함수 · 시나리오에 없는 문맥 · 섞인 표기.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i "s/^    if: .*/    if: fromJSON('true')/" "$TMP/.github/workflows/demo-scan.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "모르는 함수" "모르는 함수를 fail-closed 로 떨어뜨린다"
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i "s/^    if: .*/    if: github.event.pull_request.head.repo.fork != true/" "$TMP/.github/workflows/demo-scan.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "시나리오에 없는 문맥" "시나리오 밖 문맥을 null 로 두고 계산하지 않는다"
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i "s/^    if: .*/    if: \${{ github.event_name == 'push' }} || false/" "$TMP/.github/workflows/demo-scan.yml"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "문자열 템플릿" "감싼 식과 맨 식이 섞인 표기를 fail-closed 로 떨어뜨린다"

# 대조군 — 같은 판정의 다른 표기는 통과한다: `${{ }}` 감싸기 + 대문자(GitHub 은 문자열을 대소문자
# 없이 비교한다), 블록 스칼라. 이것이 없으면 평가기가 표기 하나만 아는 것을 알 수 없다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i "s/^    if: \(.*\)/    if: \${{ \1 }}/; s/user.login != 'dependabot\[bot\]'/user.login != 'Dependabot[bot]'/" "$TMP/.github/workflows/demo-scan.yml"
assert_contains "$(cat "$TMP/.github/workflows/demo-scan.yml")" "if: \${{ github.event_name" "대조군 입력이 실제로 감싼 표기로 바뀌었다"
assert_ok node "$GUARD" "$TMP"
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
sed -i "s/^    if: \(.*\)/    if: >-\n      \1/" "$TMP/.github/workflows/demo-scan.yml"
assert_ok node "$GUARD" "$TMP"

# 공허성 — 규칙 11 도 발견 기반이다.
rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"
assert_fails node "$GUARD" "$TMP" --min-pr-secret-jobs=99
out=$(node "$GUARD" "$TMP" --min-pr-secret-jobs=99 2>&1 || true)
assert_contains "$out" "규칙 11 이 조용히 비었을 수 있다" "PR 시크릿 잡 하한이 공허를 막는다"

# ── 규칙 11 둘째 회차 — 독립 레그 둘이 짚은 자리 ──
# 적대 레그(계약 + 코드만): 우회 셋 · 오탐 둘. 변이 레그(변이를 레그가 고름): 8 변이가 전부 SILENT 였다.
# 아래는 그 하나하나를 사례로 세운 것이다. 워크플로 모양이 여러 줄이라 sed 대신 파일째 쓴다.
fresh() { rm -rf "$TMP"; mkdir -p "$TMP"; cp -r "$FIX/." "$TMP/"; }
scan_wf() { cat > "$TMP/.github/workflows/demo-scan.yml"; }
SCAN="$TMP/.github/workflows/demo-scan.yml"
ACTOR_ONLY="github.event_name != 'pull_request' || github.actor != 'dependabot[bot]'"

# 우회 — pull_request_target 은 PR 병합 ref 가 아니라 **기준 브랜치** ref 로 돈다. 시나리오가 모든 PR 이벤트에
# `refs/pull/N/merge` 를 넣으면 `github.ref == 'refs/heads/main'` 이 PR 에서 거짓으로 보여 통과한다.
fresh
scan_wf <<'EOF'
name: demo-scan
on:
  push:
    branches: [main]
  pull_request_target:
permissions:
  contents: read
jobs:
  scan:
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - run: echo "픽스처"
        env:
          SCAN_TOKEN: ${{ secrets.DEMO_SCAN_TOKEN }}
EOF
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "(pull_request_target)에서 돈다" "pull_request_target 의 ref 를 기준 브랜치로 평가한다"

# 우회 — 시나리오의 상수 하나에 맞춘 식. Dependabot 의 target-branch 는 바꿀 수 있으므로 기준 브랜치가
# main 하나라고 가정하면 `base_ref != 'main'` 이 통과한다. 자유값은 두 벌로 평가한다.
fresh
sed -i "s/^    if: .*/    if: github.event_name == 'push' || github.base_ref != 'main'/" "$SCAN"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "Dependabot 이 연 PR 을 Dependabot 이 갱신" "기준 브랜치 하나에 맞춘 식을 다른 벌로 잡는다"

# 우회 — `jobs:` **뒤**의 최상위 env 도 모든 잡이 쥔다. 앞만 보면 마지막 잡 말고는 모른다.
fresh
scan_wf <<'EOF'
name: demo-scan
on:
  pull_request:
permissions:
  contents: read
jobs:
  early:
    runs-on: ubuntu-latest
    steps:
      - run: echo "픽스처"
  late:
    runs-on: ubuntu-latest
    if: github.event.pull_request.user.login != 'dependabot[bot]'
    steps:
      - run: echo "픽스처"
env:
  LATE: ${{ secrets.DEMO_LATE }}
EOF
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "잡 \`early\` 은 PR 에서 \`DEMO_LATE\` 를 쥐는데" "jobs: 뒤의 최상위 env 를 앞선 잡에도 건다"

# 우회 — 여러 줄 플로우 시퀀스와 앵커는 트리거를 읽지 못한다 → 빈 트리거로 넘기지 말고 fail-closed.
fresh
printf 'name: demo-scan\non: [push,\n  pull_request]\npermissions:\n  contents: read\njobs:\n  scan:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo "${{ secrets.DEMO_SCAN_TOKEN }}"\n' > "$SCAN"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "트리거를 읽을 수 없다" "여러 줄 플로우 시퀀스 on: 을 fail-closed 로 떨어뜨린다"
fresh
sed -i 's/^on:$/on: \&triggers/' "$SCAN"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "트리거를 읽을 수 없다" "앵커 붙은 on: 을 fail-closed 로 떨어뜨린다"

# 오탐 — `run:` 의 글자 `secrets.X` 는 시크릿을 쥐는 것이 아니다. 식(`${{ }}`) 안의 것만 센다.
fresh
printf '      - run: echo "missing secrets.NPM_TOKEN"\n' >> "$SCAN"
assert_ok node "$GUARD" "$TMP"
# ⚠️ 그러나 run 블록 안의 셸 주석에 든 식은 센다 — GitHub 은 셸을 모르고 run 글 전체에서 식을 치환한다.
fresh
printf '      - run: |\n          # echo ${{ secrets.DEMO_COMMENTED }}\n          true\n' >> "$SCAN"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "\`DEMO_COMMENTED\` 를 쥐는데" "run 블록 셸 주석 속 식도 시크릿을 쥔다"

# 오탐 — 여러 줄 plain 스칼라 if: (YAML 은 줄바꿈을 공백으로 접는다). 첫 줄만 읽으면 `||` 로 끝나 거부된다.
fresh
sed -i "s/^    if: \(.*\) || \((.*)\)$/    if: \1 ||\n      \2/" "$SCAN"
assert_contains "$(cat "$SCAN")" "pull_request' ||
      (github.actor" "대조군 입력이 실제로 두 줄이 됐다"
assert_ok node "$GUARD" "$TMP"

# 미고정 — 재실행 시나리오(actor 와 triggering_actor 가 갈리는 유일한 경우)가 따로 선다.
fresh
sed -i "s/^    if: .*/    if: github.event_name != 'pull_request' || github.triggering_actor != github.actor/" "$SCAN"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "다시 돌림" "재실행 시나리오만 참인 식을 잡는다"

# 미고정 — `secrets: inherit`(재사용 워크플로 호출)는 이름 없이 시크릿을 넘긴다.
fresh
printf '  call:\n    uses: ./.github/workflows/demo-reusable.yml\n    secrets: inherit # 픽스처\n' >> "$SCAN"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "잡 \`call\` 은 PR 에서 \`secrets: inherit\` 를 쥐는데" "secrets: inherit 를 시크릿으로 센다"

# 미고정 — PR 트리거가 둘이면 둘 다 평가한다.
fresh
sed -i 's/^  pull_request:$/  pull_request:\n  pull_request_target:/' "$SCAN"
sed -i "s/^    if: .*/    if: github.event_name != 'pull_request' || github.event.pull_request.user.login != 'dependabot[bot]'/" "$SCAN"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "(pull_request_target)에서 돈다" "두 번째 PR 트리거도 평가한다"

# 미고정 — 트리거 표기 셋(플로우 시퀀스 · 블록 시퀀스는 읽고, 플로우 매핑은 fail-closed).
for ON in 'on: [push, pull_request]' 'on:
  - push
  - pull_request'; do
  fresh
  printf 'name: demo-scan\n%s\npermissions:\n  contents: read\njobs:\n  scan:\n    runs-on: ubuntu-latest\n    if: %s\n    steps:\n      - run: echo "${{ secrets.DEMO_SCAN_TOKEN }}"\n' "$ON" "$ACTOR_ONLY" > "$SCAN"
  assert_fails node "$GUARD" "$TMP"
  out=$(node "$GUARD" "$TMP" 2>&1 || true)
  assert_contains "$out" "사람이 커밋을 얹음" "트리거 표기 [$(printf '%s' "$ON" | head -1)…] 를 읽어 평가한다"
done
fresh
sed -i '/^  push:$/,/^    types: /d' "$SCAN"
sed -i 's/^on:$/on: {push: {branches: [main]}, pull_request: {}}/' "$SCAN"
assert_fails node "$GUARD" "$TMP"
out=$(node "$GUARD" "$TMP" 2>&1 || true)
assert_contains "$out" "플로우 매핑이라 트리거를" "플로우 매핑 on: 을 fail-closed 로 떨어뜨린다"

# 미고정 — contains() 는 대소문자를 가리지 않는다(GitHub 과 같다). 가리면 맞는 식이 거부된다.
fresh
sed -i "s/^    if: .*/    if: github.event_name != 'pull_request' || !contains(github.event.pull_request.user.login, 'Dependabot')/" "$SCAN"
assert_ok node "$GUARD" "$TMP"

# 미고정 — 블록 스칼라의 **둘째 줄**도 식이다.
fresh
sed -i "s/^    if: \(.*\) || \((.*)\)$/    if: >-\n      \1 ||\n      \2/" "$SCAN"
assert_contains "$(cat "$SCAN")" "if: >-" "대조군 입력이 실제로 블록 스칼라가 됐다"
assert_ok node "$GUARD" "$TMP"

# ── 규칙 12: PR 에서 시크릿을 쥐는 잡은 저장소·패키지 코드를 돌리지 않는다 ──
# 규칙 11 은 Dependabot 이 연 PR 을 건너뛸 뿐이라, 사람이 연 PR 에 bump 커밋을 옮겨 담으면 미검토 패키지가 토큰과
# 한 잡에서 돈다(등록부 sonarcloud-human-pr-carries-unreviewed-bump). 정상형은 시크릿 없는 build 잡이 코드를 돌리고
# 시크릿 잡 scan 이 산출물을 runner.temp 로 받아 정해진 자리만 옮기는 모양이다.
# $1 = download 스텝의 path 줄(빈 값이면 줄이 없다) · $2 = scan 잡 레벨에 더할 줄
# ⚠️ 기본값을 `"${1-… \${{ … }}…}"` 로 쓰지 말 것 — 첫 `}` 가 매개변수 확장을 닫아 `}}` 가 `}` 하나로 깨진다(실측).
DL_TEMP='          path: ${{ runner.temp }}/in'
base_scan() {
  if [ "$#" -ge 1 ]; then _path="$1"; else _path="$DL_TEMP"; fi
  cat > "$SCAN" <<EOF
name: demo-scan
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@0000000000000000000000000000000000000000 # 픽스처
      - run: npm ci && ./gradlew build
  scan:
    needs: build
    runs-on: ubuntu-latest
    if: github.event_name != 'pull_request' || (github.actor != 'dependabot[bot]' && github.event.pull_request.user.login != 'dependabot[bot]')
${2-}
    steps:
      # npm·gradlew 는 build 잡이 돌린다 — 스텝 사이의 YAML 주석은 run 글이 아니다(오탐 대조군)
      - uses: actions/checkout@0000000000000000000000000000000000000000 # 픽스처
      - uses: actions/download-artifact@0000000000000000000000000000000000000000 # 픽스처
        with:
          name: inputs
${_path}
      - name: place
        env:
          IN: \${{ runner.temp }}/in
        run: |
          set -euo pipefail
          for f in java/a/target/x.xml go/cover.out node/coverage/lcov.info; do cp "\$IN/\$f" "\$f"; done
          echo "Java libraries for Sonar: 3 jars"
          echo "LIBS=\$IN/libs/001-a.jar" >> "\$GITHUB_ENV"
      - uses: SonarSource/sonarqube-scan-action@0000000000000000000000000000000000000000 # 픽스처
        with:
          args: -Dsonar.java.libraries=\${{ env.LIBS }}
        env:
          SONAR_TOKEN: \${{ secrets.DEMO_SCAN_TOKEN }}
EOF
}
Z=0000000000000000000000000000000000000000
# 정상형 — build 잡의 npm·gradlew·셋업 액션(시크릿 없음), scan 잡의 경로 조각(`java/…`·`go/cover.out`)·산문
# (`Java libraries`)·스텝 사이 YAML 주석은 걸리지 않는다. 이것이 없으면 「무엇이든 실패」로도 아래가 다 통과한다.
fresh; base_scan
assert_ok node "$GUARD" "$TMP"
# r12 <설명> <기대 문구> — 마지막에 쓴 $SCAN 이 실패하고 그 문구를 내는지 본다.
r12() {
  assert_fails node "$GUARD" "$TMP"
  out=$(node "$GUARD" "$TMP" 2>&1 || true)
  assert_contains "$out" "$2" "$1"
}
fresh; base_scan; printf '      - run: npm ci\n' >> "$SCAN"
r12 "시크릿 잡의 설치 명령을 잡는다" "의 \`run:\` 이 \`npm\` 를 부른다"
fresh; base_scan; printf '      - run:\n          npm ci\n' >> "$SCAN"
r12 "다음 줄로 넘어간 plain 스칼라 run 도 읽는다" "의 \`run:\` 이 \`npm\` 를 부른다"
fresh; base_scan; printf '      - run: /usr/bin/node x.js\n' >> "$SCAN"
r12 "절대경로로 부른 인터프리터를 잡는다" "\`node\` 를 부른다"
fresh; base_scan; printf '      - run: bash scripts/x.sh\n' >> "$SCAN"
r12 "셸로 저장소 스크립트를 부르면 잡는다" "\`bash\` 를 부른다"
fresh; base_scan; printf '      - run: ./gradlew koverXmlReport\n' >> "$SCAN"
r12 "명령 자리의 상대경로 실행을 잡는다" "파일을 실행한다"
fresh; base_scan; printf '      - run: |\n          set -e\n          . ./env.sh\n' >> "$SCAN"
r12 "점 소싱을 잡는다" "파일을 실행한다"
# 엄격한 쪽으로 고정 — run 글의 셸 주석은 걷지 않는다(`"#"` 안팎을 셸처럼 못 가리면 걷는 쪽이 뒤를 숨긴다).
fresh; base_scan; printf '      - run: |\n          # npm ci\n          true\n' >> "$SCAN"
r12 "run 글 안의 셸 주석도 센다" "\`npm\` 를 부른다"
fresh; base_scan; printf '      - uses: actions/setup-java@%s # 픽스처\n' "$Z" >> "$SCAN"
r12 "허용 목록 밖 셋업 액션을 잡는다" "이 \`actions/setup-java\` 를 쓴다"
fresh; base_scan; printf '      - uses: ./.github/actions/build\n' >> "$SCAN"
r12 "로컬 액션을 잡는다" "이 \`./.github/actions/build\` 를 쓴다"
fresh; base_scan; printf '      - uses: docker://alpine:3.20\n' >> "$SCAN"
r12 "docker:// 액션을 잡는다" "이 \`docker://alpine:3.20\` 를 쓴다"
fresh; base_scan; printf '      - uses: SonarSource/sonarqube-scan-action@%s # 픽스처\n        with:\n          skipSignatureVerification: true\n' "$Z" >> "$SCAN"
r12 "스캐너 서명 검증 끄기를 잡는다" "서명 검증·출처를 바꾼다(\`skipSignatureVerification\`)"
fresh; base_scan '          path: in'
r12 "산출물을 워크스페이스에 풀면 잡는다" "가 \`path: \${{ runner.temp }}/…\` 가 아니다"
fresh; base_scan ''
r12 "path 없는 download(기본값 = 워크스페이스)를 잡는다" "가 \`path: \${{ runner.temp }}/…\` 가 아니다"
fresh; base_scan; printf '      - run: echo "${{ needs.build.outputs.cmd }}"\n' >> "$SCAN"
r12 "run 의 앞 잡 출력(스크립트 주입)을 잡는다" "앞 잡의 출력은 그 잡의 코드가 정한 글자다"
fresh; base_scan; printf '      - uses: SonarSource/sonarqube-scan-action@%s # 픽스처\n        with:\n          args: ${{ needs.build.outputs.args }}\n' "$Z" >> "$SCAN"
r12 "스캔 args 의 앞 잡 출력(속성 주입)을 잡는다" "앞 잡의 출력은 그 잡의 코드가 정한 글자다"
fresh; base_scan; printf '      - shell: python\n        run: print(1)\n' >> "$SCAN"
r12 "bash·sh 밖의 셸을 잡는다" "\`shell: python\`"
fresh; base_scan; sed -i 's/^jobs:$/defaults:\n  run:\n    shell: pwsh\njobs:/' "$SCAN"
assert_contains "$(cat "$SCAN")" "    shell: pwsh" "(변이가 착지했는지 먼저 본다)"
r12 "워크플로 최상위 defaults 의 셸도 잡는다" "워크플로 최상위 의 \`shell: pwsh\`"
fresh; base_scan; printf '      - uses: actions/checkout@%s # 픽스처\n        env:\n          NODE_OPTIONS: --require ./hook.js\n' "$Z" >> "$SCAN"
r12 "env 의 로더 훅을 잡는다" "로더 훅 \`NODE_OPTIONS\`"
fresh; base_scan; printf '      - run: echo "JAVA_TOOL_OPTIONS=-javaagent:x.jar" >> "$GITHUB_ENV"\n' >> "$SCAN"
r12 "GITHUB_ENV 로 쓰는 로더 훅을 잡는다" "로더 훅 \`JAVA_TOOL_OPTIONS\`"
fresh; base_scan; printf '      - run: echo "$RUNNER_TEMP/in/bin" >> "$GITHUB_PATH"\n' >> "$SCAN"
r12 "GITHUB_PATH 쓰기를 잡는다" "\`\$GITHUB_PATH\` 를 고친다"
fresh; base_scan "$DL_TEMP" '    container: node:22'
r12 "잡 레벨 container 를 잡는다" "잡 레벨 \`container:\` 를 쓴다"
fresh; printf '  call:\n    uses: ./.github/workflows/demo-reusable.yml\n    secrets: inherit # 픽스처\n' >> "$SCAN"
r12 "재사용 워크플로 호출을 잡는다" "잡 \`call\`(PR 에서 시크릿을 쥔다) 이 잡 레벨 \`uses:\` 를 쓴다"

# ── 오탐 대조군 3: 저장소 루트 실물에 대해 통과해야 한다 ──
# 픽스처에서만 도는 가드는 실제 트리와 어긋난 채로 초록불을 유지할 수 있다.
assert_ok node "$GUARD" "$DIR/../.."
# 실측 하한과 함께 돌려도 통과해야 한다(CI 가 넘기는 값과 같은 모양).
assert_ok node "$GUARD" "$DIR/../.." --min-escalations=6 --min-pr-secret-jobs=1

assert_report
