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
# 반대 방향(과대주장 방지)도 고정한다 — 셋 게시했다고 전부 게시된 것은 아니다. 이 문구는
# 문서와 이 테스트가 **같은 커밋에서 함께** 갱신되는 카운트다(환경이 아니라 문서만 읽으므로
# 체크아웃 안에서 항상 자기일관 — 다음 언어가 게시되면 문서와 이 줄을 한 PR에서 같이 고친다).
assert_contains "$body" "The other six languages are unpublished" \
  "나머지 여섯 언어가 미게시라는 사실이 문서에서 사라졌다"
assert_report
