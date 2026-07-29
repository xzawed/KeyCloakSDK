#!/usr/bin/env sh
# release-trigger.sh — 언어·버전 입력 시 정확한 태그 push 명령 + 사전 체크리스트를 "출력만" 한다.
# ⚠️ human-gate: 이 스크립트는 git tag/push를 절대 실행하지 않는다. 출력된 명령은 사람이 복사해 실행한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib/deploy-facts.sh"

usage() { echo "usage: release-trigger.sh <lang> <version>   (lang: $DEPLOY_LANGS; version: X.Y.Z)" >&2; exit 1; }

[ $# -eq 2 ] || usage
LANG_="$1"; VER="$2"
df_known "$LANG_" || { echo "error: unknown lang '$LANG_'" >&2; usage; }
# semver X.Y.Z 검증(프리릴리스 접미 미지원 — 필요 시 확장)
echo "$VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "error: version must be X.Y.Z (got '$VER')" >&2; usage; }

TAG="$(printf "$(df_tag "$LANG_")" "$VER")"
BUMP="$(df_versionbump "$LANG_")"
AUTH="$(df_auth "$LANG_")"

printf '=== 릴리스 트리거 안내: %s v%s ===\n\n' "$LANG_" "$VER"

printf '1) 버전 범프\n'
case "$BUMP" in
  none*|auto*) printf '   버전 파일 수정 불필요 — %s\n' "$BUMP" ;;
  *) printf '   ⚠️ 태그 push 전에 수동으로 올릴 것: %s → 값을 %s로\n' "$BUMP" "$VER" ;;
esac

printf '\n2) dry-run (배포 없이 로컬 산출물 검증)\n   %s\n' "$(df_dryrun "$LANG_")"

printf '\n3) 사전 점검\n   ./scripts/release-readiness.sh %s   # 시크릿·레지스트리·태그 상태 확인\n' "$LANG_"
case "$AUTH" in
  OIDC) printf '   ℹ️ OIDC: pending-publisher가 %s에 사전등록돼 있어야 함(owner=xzawed/repo=KeyCloakSDK/workflow=%s)\n' "$(df_registry "$LANG_")" "$(basename "$(df_workflow_hint "$LANG_")")" ;;
  maven-gpg) printf '   ℹ️ Maven: 배포는 Central Portal 스테이징까지만 자동 — 이후 Portal 콘솔에서 사람이 수동 Publish(2단계)\n' ;;
  api-token)
    # rust·dotnet 둘 다 fail-closed다. dotnet은 예전에 시크릿 미설정 시 exit 0으로 조용히 스킵해
    # green 실행에서 "게시되지 않은 버전이 게시된 것처럼" 보였으나, 지금은 ::error:: 후 exit 1이다.
    printf '   ℹ️ api-token: %s 시크릿이 등록돼 있어야 함(미설정 시 하드 실패 — rust·dotnet 둘 다 fail-closed)\n' "$(df_secrets "$LANG_")"
    if [ "$LANG_" = dotnet ]; then
      printf '   ℹ️ dotnet: `dotnet nuget push`에서 --skip-duplicate가 제거됨 — 이미 존재하는 버전이면 성공으로 위장하지 않고 실패한다\n'
    fi
    ;;
  split-token)
    # Packagist는 이 모노레포를 볼 수 없다 — Composer VCS 드라이버는 저장소 **루트**의 composer.json만
    # 읽는데 이 리포 루트엔 없다(php/composer.json 하나뿐). 그래서 php-release.yml의 split 잡이
    # php/ 하위트리를 떼어 미러 저장소로 push하고, Packagist는 그 미러를 추적한다.
    printf '   ℹ️ split-token: %s 시크릿(미러 저장소 write 권한)이 등록돼 있어야 함 — 미설정 시 하드 실패\n' "$(df_secrets "$LANG_")"
    printf '   ℹ️ 1회 사람 선행작업: 미러 저장소 xzawed/keycloak-sdk-php 생성 → **그 저장소를** Packagist에 등록\n'
    printf '   ℹ️ split 잡이 `git subtree split --prefix=php` 결과를 미러 main에 force-push하고 접두어 없는 v%s 태그를 거기에 만든다(Composer는 php-v 접두를 버전으로 파싱하지 못함)\n' "$VER"
    printf '   ℹ️ 미러에 v%s 태그가 이미 있으면 push가 실패한다(의도 — 태워버린 버전을 사람이 알아채야 함)\n' "$VER"
    ;;
  none) printf '   ℹ️ 무설정: 태그 push 시 Go 프록시가 자동 캐시\n' ;;
esac

printf '\n4) 태그 push (⚠️ 사람이 직접 실행 — 이 스크립트는 실행하지 않음)\n   git tag %s && git push origin %s\n' "$TAG" "$TAG"

printf '\n5) 배포 확인\n   GitHub Actions에서 %s 워크플로 성공 확인' "$LANG_"
[ "$AUTH" = maven-gpg ] && printf ' → Central Portal 콘솔에서 수동 Publish'
INST="$(printf "$(df_install "$LANG_")" "$VER")"
printf '\n   배포 후 설치: %s\n' "$INST"
