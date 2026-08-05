#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
DOC="$DIR/../../DEPLOY.md"
body="$(cat "$DOC")"

# 9개 언어 섹션·태그·시크릿·설치좌표가 모두 문서에 존재
for L in $DEPLOY_LANGS; do
  assert_contains "$body" "$(printf "$(df_tag "$L")" X.Y.Z | sed 's/X.Y.Z/*/')" "태그포맷 $L"
  for s in $(df_secrets "$L"); do assert_contains "$body" "$s" "시크릿 $s"; done
done
# 두 도우미 스크립트 참조
assert_contains "$body" "scripts/release-readiness.sh" "readiness 참조"
assert_contains "$body" "scripts/release-trigger.sh" "trigger 참조"
# 인증모델 그룹 헤딩 존재
# ⚠️ DEPLOY.md는 사용자 대상 문서라 영문이다(문서 언어 규칙). 예전 이 어서션은 한글 "준비상태
# 매트릭스"를 찾고 있었는데 문서가 영문으로 번역되면서 계속 실패하고 있었다(이 테스트는 어떤 CI
# 워크플로에도 연결돼 있지 않아 드리프트가 드러나지 않았다). 헤딩 텍스트 기준으로 맞춘다.
assert_contains "$body" "Readiness Matrix" "매트릭스 섹션"
assert_contains "$body" "human-gate" "human-gate 원칙"

# 권장 순서는 복구가능성 축이다(deploy-facts.sh의 DEPLOY_LANGS와 같은 순서를 문서도 말해야 한다).
order="$(echo "$DEPLOY_LANGS" | sed 's/ / → /g')"
assert_contains "$body" "$order" "권장 배포 순서(복구가능성) = DEPLOY_LANGS"

# PHP는 웹훅이 아니라 subtree split 미러다 — 미러 저장소·시크릿·1회 사람 설정이 문서에 있어야 한다.
assert_contains "$body" "xzawed/keycloak-sdk-php" "PHP 미러 저장소"
assert_contains "$body" "git subtree split --prefix=php" "PHP split 방식"

# 시크릿 미설정이 "조용한 스킵"이라는 옛 서술이 남아 있으면 안 된다(dotnet·kotlin 둘 다 fail-closed).
assert_not_contains "$body" "silently skipped" "조용한 스킵 서술 잔존"
assert_not_contains "$body" "silently skips" "조용한 스킵 서술 잔존(2)"

# 게시 이력에 대한 정직성 — ⚠️ 이 어서션은 두 번 잘못 설계됐다. 그 이력을 남긴다.
#
# (1) 처음에는 `assert_contains "$body" "zero tags"`였다. 낡음을 잡으라고 둔 어서션인데, 사실이
#     바뀌자(첫 태그 `php-v0.1.0-rc.1`) **낡은 주장을 강제하는 쪽으로 뒤집혔다** — 문서를 진실에
#     맞추면 테스트가 빨간불이 되는 상태. 상수를 못박은 가드의 전형적 실패다.
# (2) 그래서 `git tag -l`과 대조하도록 바꿨는데 그것도 틀렸다. CI의 `actions/checkout`은 기본적으로
#     **태그를 가져오지 않아** 거기서는 항상 0이다. "실제와 대조"한다고 믿었지만 실제로는 체크아웃
#     산물에 기댄 것이었고, 로컬 통과·CI 실패로 드러났다.
#
# 지금은 **환경과 무관하게 참인 것**에 건다: 게시는 단방향이다. 한번 태그를 밀고 한번 레지스트리에
# 올라가면 그 사실은 되돌아가지 않으므로, 아래 절대 표현들은 앞으로 영원히 거짓이다. 존재 여부만
# 보면 되고 네트워크도 git 상태도 필요 없다.
assert_not_contains "$body" "zero tags" "이미 태그가 밀렸는데 문서가 'zero tags'라고 주장한다"
assert_not_contains "$body" "has ever executed, not once" "릴리스 워크플로가 실행됐는데 '한 번도 없다'고 주장한다"
assert_not_contains "$body" "nothing has ever been published to a public registry" \
  "PHP가 Packagist에 게시됐는데 문서가 '어디에도 게시된 적 없다'고 주장한다"
# python(py-v0.1.0rc1 → PyPI)·dotnet(dotnet-v0.1.0-rc.1 → NuGet)이 게시되면서 늘어난
# 영원-거짓 절대 표현들 — 같은 단방향 원리로 금지 목록에 추가한다.
assert_not_contains "$body" "Exactly one tag has ever been pushed" \
  "태그가 셋인데 문서가 '정확히 하나'라고 주장한다"
assert_not_contains "$body" "The other eight languages are unpublished" \
  "python·dotnet이 게시됐는데 문서가 '나머지 여덟 미게시'라고 주장한다"
assert_not_contains "$body" "what remains is the Packagist registration" \
  "Packagist 등록이 끝났는데 문서가 '등록이 남았다'고 주장한다"
# 밀린 태그·게시 사실 자체는 단방향(한번 참이면 영원히 참)이라 존재 어서션이 안전하다 —
# 문서가 게시 이력을 기록에서 지우면 잡는다.
assert_contains "$body" "php-v0.1.0-rc.1" "PHP 첫 태그(리허설) 기록"
assert_contains "$body" "py-v0.1.0rc1" "Python 첫 태그 기록"
assert_contains "$body" "dotnet-v0.1.0-rc.1" ".NET 첫 태그 기록"
assert_contains "$body" "rust-v0.1.0-rc.1" "Rust 첫 태그 기록"
# (과대주장 방지 — "나머지 N개는 미게시"는 아래 SSOT 블록이 파생값으로 대조한다.)

# ---- 게시 현황을 SSOT(`DF_PUBLISHED`)로 대조한다 ----
#
# ⚠️ **어서션이 변별력을 갖는지 반드시 변이로 확인할 것.** 이 블록의 첫 판은 게시된 언어의
# **이름**이 DEPLOY.md에 있는지만 봤는데, 그건 아무것도 잡지 못했다 — 이 문서에서 미게시 언어가
# 게시 언어보다 오히려 더 자주 등장한다(실측: Go 26회·Ruby 24회 vs Rust 10회·.NET 12회). 즉
# "Rust가 언급된다"는 게시 여부와 무관하게 항상 참이라 초록불이 커버리지처럼 보일 뿐이었다.
# 실제로 crates.io 문구를 라이브 목록에서 지우는 변이가 통과했다.
#
# 대신 **게시된 언어만 등장할 수 있는 자리**에 건다: DEPLOY.md 첫머리의 "무엇이 지금 레지스트리에
# 살아있는가" 한 문장. 거기에 각 언어의 레지스트리명과 좌표가 있어야 한다.
live="$(printf '%s\n' "$body" | grep -F 'live on public registries')"
# 이 grep이 빈 값을 돌려주면(문구가 바뀌면) 아래 어서션이 전부 실패한다 — 조용히 통과하는
# 것보다 시끄럽게 실패하는 쪽이 맞다. 다만 원인이 드러나도록 여기서 먼저 잡는다.
assert_ok test -n "$live"
for _dfl in $DF_PUBLISHED; do
  assert_ok df_known "$_dfl"   # SSOT 오타 방지 — DEPLOY_LANGS에 없는 토큰은 모든 소비자를 조용히 망가뜨린다
  assert_contains "$live" "$(df_registry "$_dfl")" "게시된 $_dfl 의 레지스트리가 라이브 목록에 없다"
  assert_contains "$live" "$(df_coordinate "$_dfl")" "게시된 $_dfl 의 좌표가 라이브 목록에 없다"
done

# ⚠️ 미게시 언어는 **존재를 요구하지 않는다** — 그것이 (1)의 함정이다. 미게시는 되돌릴 수 있는
# (게시하면 끝나는) 상태라, "미게시라고 적혀 있어야 한다"는 어서션은 게시하는 순간 낡은 주장을
# 강제한다. 대신 문서가 말하는 미게시 **개수**가 SSOT에서 파생한 값과 맞는지만 본다 — 이쪽은
# 양방향이라(문서만 고쳐도, SSOT만 고쳐도) 한쪽만 움직이면 잡힌다.
pub_n=0; for _dfl in $DF_PUBLISHED; do pub_n=$((pub_n + 1)); done
all_n=0; for _dfl in $DEPLOY_LANGS; do all_n=$((all_n + 1)); done
unpub_n=$((all_n - pub_n))
case "$unpub_n" in
  1) _w="one" ;; 2) _w="two" ;; 3) _w="three" ;; 4) _w="four" ;; 5) _w="five" ;;
  6) _w="six" ;; 7) _w="seven" ;; 8) _w="eight" ;; 9) _w="nine" ;;
  *) _w="" ;;
esac
assert_ok test -n "$_w"
assert_contains "$body" "The other $_w languages are unpublished" \
  "DEPLOY.md의 미게시 개수 문구가 DF_PUBLISHED에서 파생한 $unpub_n 과 다르다"
assert_report
