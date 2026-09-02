#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"

# 9개 언어 존재·순서 — 순서축은 "쉬운 인증"이 아니라 **복구가능성**이다(yank 가능 → Central Portal
# 2단계 게이트 → 프록시 캐시 후 불변인 go → 미러 저장소 신설이 선행되는 php).
assert_eq "python dotnet ruby node rust java kotlin go php" "$DEPLOY_LANGS" "DEPLOY_LANGS 순서(복구가능성)"
assert_ok df_known python; assert_fails df_known perl
# 태그 포맷(버전 주입)
assert_eq "py-v0.1.0" "$(printf "$(df_tag python)" 0.1.0)" "python 태그"
assert_eq "go/v0.1.0" "$(printf "$(df_tag go)" 0.1.0)" "go 태그"
assert_eq "v0.1.0" "$(printf "$(df_tag java)" 0.1.0)" "java 태그"
assert_eq "kotlin-v0.1.0" "$(printf "$(df_tag kotlin)" 0.1.0)" "kotlin 태그"
# 시크릿(정확 이름·개수)
assert_eq "MAVEN_GPG_PRIVATE_KEY MAVEN_GPG_PASSPHRASE CENTRAL_TOKEN_USER CENTRAL_TOKEN_PW" "$(df_secrets java)" "java 시크릿"
assert_eq "MAVEN_CENTRAL_USERNAME MAVEN_CENTRAL_PASSWORD SIGNING_IN_MEMORY_KEY SIGNING_IN_MEMORY_KEY_PASSWORD" "$(df_secrets kotlin)" "kotlin 시크릿"
assert_eq "NUGET_API_KEY" "$(df_secrets dotnet)" "dotnet 시크릿"
assert_eq "CARGO_REGISTRY_TOKEN" "$(df_secrets rust)" "rust 시크릿"
# php는 subtree split 미러 push에 write 토큰이 필요하다 — 예전처럼 시크릿 0개가 아니다.
# (0개면 rr_verdict가 "✅ 준비완료"로 오탐한다 — 미러/토큰 미설정 상태에서 false green.)
assert_eq "PHP_SPLIT_TOKEN" "$(df_secrets php)" "php 시크릿"
assert_eq "" "$(df_secrets python)" "python 시크릿 없음"
assert_eq "" "$(df_secrets go)" "go 시크릿 없음"
# auth 모델
assert_eq "none" "$(df_auth go)" "go auth"
# php는 webhook이 아니다 — Packagist는 이 모노레포를 추적할 수 없어(루트 composer.json 부재)
# php/ 하위트리를 미러 저장소로 split-push하는 것이 유일한 게시 경로다.
assert_eq "split-token" "$(df_auth php)" "php auth(split-token)"
assert_eq "api-token" "$(df_auth rust)" "rust auth"
assert_eq "OIDC" "$(df_auth python)" "python auth"
assert_eq "maven-gpg" "$(df_auth java)" "java auth"
# 설치 좌표(go는 버전 주입)
assert_eq "go get github.com/xzawed/KeyCloakSDK/go@v0.1.0" "$(printf "$(df_install go)" 0.1.0)" "go 설치"
assert_eq "pip install keycloak-sdk" "$(df_install python)" "python 설치"
# 워크플로 힌트(Task 2 소비 예정)
assert_eq "python-release.yml" "$(df_workflow_hint python)" "python 워크플로 힌트"
assert_eq "" "$(df_workflow_hint go)" "go 워크플로 힌트 없음"
# 프리릴리스 판정
assert_ok   df_is_prerelease 0.1.0rc1
assert_fails df_is_prerelease 0.1.0
# ⚠️ dash 전용 회귀(bash에서는 재현되지 않는다): 판정이 `echo "$1" | grep`이면 dash의 echo가
# `\c`를 이스케이프로 확장해 '0.1.0\c-rc.1'을 '0.1.0'으로 잘라내고 **프리릴리스를 정식
# 릴리스로 오판**한다(RC가 저장소의 Latest release로 걸리는 사고와 같은 경로). 단따옴표는
# 모든 POSIX 셸에서 백슬래시를 리터럴로 보존하므로 여기서 node가 필요하지 않다.
assert_ok df_is_prerelease '0.1.0\c-rc.1'
assert_ok df_is_prerelease '0.1.0\n0.1.0'

# 버전범프 모드 — 산문(df_versionbump)이 아니라 기계가독 값으로 분류한다.
# 이 분류가 틀리면 dispatch-release.yml의 매니페스트 대조가 자동범프 언어를 영구 차단한다
# (java는 POM이 설계대로 `-SNAPSHOT`이라 어떤 버전으로도 대조를 통과할 수 없었다).
for L in go php dotnet java; do assert_eq "auto" "$(df_bump_mode "$L")" "$L: 자동범프(태그가 버전 SSOT)"; done
for L in rust python node ruby kotlin; do assert_eq "manual" "$(df_bump_mode "$L")" "$L: 수동범프(매니페스트 대조 대상)"; done
# 빈 값은 "대조 안 함"으로 조용히 흡수되므로 아홉이 빠짐없이 분류되는지 개수로 못박는다
# (DEPLOY.md §1의 "Automatic (4) / Manual (5)"와 같은 사실이다).
assert_eq "4" "$(for L in $DEPLOY_LANGS; do df_bump_mode "$L"; done | grep -c '^auto$')" "자동범프 4개"
assert_eq "5" "$(for L in $DEPLOY_LANGS; do df_bump_mode "$L"; done | grep -c '^manual$')" "수동범프 5개"

# 모든 언어가 전 필드에 비어있지 않은 값을 반환하는지(check_url 제외 — go는 특수)
for L in $DEPLOY_LANGS; do
  for F in registry auth tag versionbump bump_mode dryrun install coordinate; do
    v="$(df_$F "$L")"; assert_ok test -n "$v"
  done
done

# ---- DF_PUBLISHED(게시 현황 SSOT) ----
# ⚠️ **오타 하나가 SSOT를 조용히 망가뜨린다.** `DF_PUBLISHED="… rusty"`로 써도 개수 기반
# 어서션은 전부 통과하는데(토큰 4개는 그대로다), `df_is_published rust`는 거짓이 되고
# `df_unpublished`는 rust를 미게시로 흘린다 — 모든 소비자가 틀린 답을 받으면서 CI는 초록이다.
# 그래서 멤버십부터 검사한다.
for L in $DF_PUBLISHED; do
  assert_ok df_known "$L"
done
assert_ok df_is_published php   # 게시는 단방향이라 이 어서션은 영원히 참이다
assert_fails df_is_published perl   # 언어가 아닌 토큰
# ⚠️ **미게시 언어를 이름으로 못박지 말 것.** 여기 한때 `assert_fails df_is_published ruby`가
# 있었고, ruby를 게시하는 날 그 줄이 **낡은 사실을 강제하는 쪽으로 뒤집혔다**(문서를 진실에
# 맞추면 테스트가 빨개지는 상태) — `test-deploy-md.sh` 상단이 기록한 "zero tags" 실패와 같은
# 부류다. 검사하려는 것은 "알려진 언어인데 미게시면 false"라는 **접근자의 동작**이지 특정
# 언어가 아니므로, 대상을 SSOT에서 뽑는다.
# ⚠️ **2026-08-17: 이 검사의 대상이 사라졌다.** 예전 판은 `df_unpublished`의 첫 원소를 실제
# 대상으로 삼았는데, 아홉 전부 게시되면서 그 목록이 비어 `test -n`·`df_known`이 빈 문자열로
# 2건 실패했다(go 게시 실측). 대상이 저장소의 **게시 상태**에 묶여 있던 것이 문제다 —
# 검사하려는 것은 "알려진 언어인데 미게시면 false"라는 **접근자의 동작**이지 특정 시점의
# 게시 현황이 아니다. 그래서 대상을 **합성**한다: 서브셸에서 `DF_PUBLISHED`를 한 언어만큼
# 좁혀 그 상황을 만들고 접근자가 어떻게 답하는지 직접 본다. 이 형태는 게시 상태와 무관하게
# 성립하므로 열 번째 언어가 와도, 전부 게시돼도 다시 낡지 않는다.
# ⚠️ 서브셸 안에서 대입해야 한다 — 현재 셸에서 `DF_PUBLISHED`를 건드리면 이 파일의 나머지
# 어서션이 전부 가짜 SSOT를 보게 된다.
_pub_with()   { ( DF_PUBLISHED="$1"; df_is_published "$2" ); }   # $1=가상 SSOT $2=언어
_unpub_with() { ( DF_PUBLISHED="$1"; df_unpublished ); }
_synth_lang="$(printf '%s\n' $DEPLOY_LANGS | head -n1)"
_synth_pub=""
for L in $DEPLOY_LANGS; do
  [ "$L" = "$_synth_lang" ] || _synth_pub="$_synth_pub $L"
done
assert_ok test -n "$_synth_lang"
assert_ok df_known "$_synth_lang"
# 양방향: 같은 언어가 가상 SSOT에서는 미게시, 실제 SSOT에서는 게시로 답해야 한다.
assert_fails _pub_with "$_synth_pub"    "$_synth_lang"
assert_ok    _pub_with "$DF_PUBLISHED"  "$_synth_lang"
# 그리고 `df_unpublished`가 정확히 그 언어만 흘려야 한다(`printf '%s '`라 후행 공백이 붙는다).
assert_eq "$_synth_lang " "$(_unpub_with "$_synth_pub")" \
  "가상 SSOT에서 df_unpublished 가 제외한 언어만 흘리지 않는다"
# df_unpublished = DEPLOY_LANGS − DF_PUBLISHED (원소·개수 둘 다)
unp="$(df_unpublished)"
for L in $DEPLOY_LANGS; do
  if df_is_published "$L"; then
    assert_fails test "${unp#*"$L"}" != "$unp"   # 게시된 언어는 미게시 목록에 없어야 한다
  else
    assert_ok test "${unp#*"$L"}" != "$unp"
  fi
done
n_all=0; for L in $DEPLOY_LANGS; do n_all=$((n_all + 1)); done
n_pub=0; for L in $DF_PUBLISHED; do n_pub=$((n_pub + 1)); done
n_unp=0; for L in $unp; do n_unp=$((n_unp + 1)); done
assert_eq "$((n_all - n_pub))" "$n_unp" "df_unpublished 개수 = 전체 − 게시"
# df_published_version ↔ DF_PUBLISHED 자기정합성.
#
# ⚠️ **양방향이라야 의미가 있다.** "게시된 언어는 버전이 있다"만 검사하면 미게시 언어에 버전을
# 남겨둔 채 `DF_PUBLISHED`에서만 빼는 절반짜리 되돌리기를 통과시키고, 그 반대만 검사하면 새
# 언어가 게시될 때 빈 값을 통과시킨다. 두 방향을 함께 걸면 SSOT 한 줄을 옮길 때 둘이 같이 움직인다.
# 그리고 값은 그 언어의 표기 규칙(`df_version_re`)을 만족해야 한다 — 표기가 레지스트리마다
# 다르고(PEP 440·RubyGems 점·Maven 대문자 RC·SemVer) 틀리면 태그↔매니페스트 가드가 막는다.
# ⚠️ `assert_ok`는 인자를 **명령으로 실행**한다 — 메시지를 덧붙이면 그게 `test`의 피연산자가 되어
# 어서션이 문법오류로 실패한다(여기서 실제로 겪었다). 메시지를 남기려면 `assert_eq`를 쓴다.
for L in $DEPLOY_LANGS; do
  _v="$(df_published_version "$L")"
  if df_is_published "$L"; then
    assert_eq "nonempty" "$([ -n "$_v" ] && echo nonempty || echo empty)" \
      "$L 은 게시됐는데 df_published_version 이 비어 있다"
    assert_eq "match" "$(printf '%s' "$_v" | grep -qE "$(df_version_re "$L")" && echo match || echo nomatch)" \
      "$L 의 게시 버전 [$_v] 이 그 언어의 표기 규칙에 맞지 않는다"
  else
    assert_eq "" "$_v" "$L 은 미게시인데 df_published_version 이 값을 갖는다"
  fi
done

# ⚠️ 호출자의 루프 변수를 밟지 않아야 한다(POSIX sh에 이식 가능한 `local`이 없다).
# 이 대조군이 없으면 함수가 `_l` 같은 흔한 이름을 쓰다가 호출자 이터레이터를 덮어써도 모른다.
_l="sentinel"; df_unpublished > /dev/null; assert_eq "sentinel" "$_l" "df_unpublished 가 호출자의 _l 을 밟았다"

# ---- df_api_baseline ↔ 일곱 사본 ----
#
# 공개 API 게이트의 기준선은 일곱 파일에 리터럴로 박혀 있었고 **그것을 보는 자리가 없었다**.
# 안 올리면 각 `<lang>/README.md` 와 `SECURITY.md` 의 「직전 게시본과 대조한다」가 거짓이 되고,
# 게이트는 옛 좌표와 비교하며 **조용히 통과**한다.
#
# ⚠️ **`df_published_version` 과 같다고 단언하지 않는다.** 둘은 반대 일정으로 움직인다 —
# SSOT/배너는 태그 **전**(DEPLOY.md §4 step 1), 기준선은 게시 **후**(step 9). 순진한 등식은
# 릴리스 준비 커밋마다 빨개진다. 여기서 보는 것은 **선언 ↔ 사본의 일치**뿐이다.
_ab_root="$(cd "$DIR/../.." && pwd)"
_ab_seen=0
for _ab in $DEPLOY_LANGS; do
  case "$_ab" in
    java)   _ab_got="$(grep -oE '<japicmp\.baseline>[^<]*' "$_ab_root/java/pom.xml" | sed 's/.*>//')" ;;
    kotlin) _ab_got="$(grep -oE "BASELINE: '[^']*'" "$_ab_root/.github/workflows/kotlin-ci.yml" | sed "s/.*'\\(.*\\)'/\\1/")" ;;
    node)   _ab_got="$(grep -oE "BASELINE: '[^']*'" "$_ab_root/.github/workflows/node-ci.yml"   | sed "s/.*'\\(.*\\)'/\\1/")" ;;
    ruby)   _ab_got="$(grep -oE "BASELINE: '[^']*'" "$_ab_root/.github/workflows/ruby-ci.yml"   | sed "s/.*'\\(.*\\)'/\\1/")" ;;
    python) _ab_got="$(grep -oE -- '--against [A-Za-z0-9.-]*' "$_ab_root/.github/workflows/python-ci.yml" | sed 's/--against //')" ;;
    php)    _ab_got="$(grep -oE 'git archive [A-Za-z0-9.-]*'  "$_ab_root/.github/workflows/php-ci.yml"    | sed 's/git archive //')" ;;
    dotnet) _ab_got="$(grep -oE '<PackageValidationBaselineVersion>[^<]*' "$_ab_root/dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj" | sed 's/.*>//')" ;;
    *)      _ab_got="" ;;   # rust·go — 자리 없음
  esac
  _ab_want="$(df_api_baseline "$_ab")"
  [ -n "$_ab_want" ] && _ab_seen=$((_ab_seen + 1))
  assert_eq "$_ab_want" "$_ab_got" \
    "$_ab 의 API 게이트 기준선이 df_api_baseline 선언과 다르다 — 게이트가 옛 좌표와 비교하며 조용히 통과한다"
done
# ⚠️ 공허성 — 추출이 전부 빈 문자열이면 위 루프가 ""=="" 로 조용히 통과한다.
assert_eq "7" "$_ab_seen" "df_api_baseline 이 선언한 자리가 정확히 일곱이어야 한다(rust·go 는 자리 없음)"

# ---- Central 수동 게시 스위치 두 자리 ----
#
# Maven Central 은 게시 후 철회 수단이 **전혀 없다**(DEPLOY.md §6 — 다른 여덟 레지스트리와
# 다른 유일한 자리다). 두 JVM 레인의 회복 지점은 「Portal 스테이징에서 사람이 Publish 를
# 누르기 전」 하나뿐이고, 그 성질을 소유하는 것이 이 두 스위치다:
#
#     java/pom.xml             <autoPublish>false</autoPublish>
#     kotlin/build.gradle.kts  publishToMavenCentral(automaticRelease = false)
#
# ⚠️ 두 파일의 주석이 **「기본값 상속에 기대면 안 된다」고 이미 적어 놓았는데 그것을 보는
# 자리가 없었다** — 변이 실측: 둘을 `true` 로 뒤집어도 가드 23/23 과 check-docs 가 전부 통과했다.
# 값을 뒤집는 변이는 리뷰에서 한 글자로 보이고, 그 대가는 되돌릴 수 없는 게시다.
#
# 기대값을 리터럴 `false` 로 박는 것이 맞다 — 이것은 버전처럼 움직이는 값이 아니라 **정책**이고,
# 바꾸려면 사람이 이 어서션을 함께 지워야 한다(그게 목적이다).
_cp_java="$(grep -oE '<autoPublish>[^<]*' "$_ab_root/java/pom.xml" | sed 's/.*>//' | head -1)"
_cp_kt="$(grep -oE 'publishToMavenCentral\(automaticRelease *= *[A-Za-z]+' "$_ab_root/kotlin/build.gradle.kts" | sed 's/.*= *//' | head -1)"
assert_eq "false" "${_cp_java:-없음}" \
  "java/pom.xml 의 <autoPublish> 가 false 가 아니다 — Central 은 게시 후 철회가 없고 사람의 Publish 클릭이 유일한 회복 지점이다"
assert_eq "false" "${_cp_kt:-없음}" \
  "kotlin/build.gradle.kts 의 automaticRelease 가 false 가 아니다 — 위와 같은 이유(자매 레인이라 함께 무너진다)"

# ---- examples 모듈을 Central 번들에서 빼는 유일한 자리 ----
#
# `keycloak-sdk-examples` 는 소비자 좌표가 아닌데 `0.1.0-RC1`·`0.1.0` 이 실제로 repo1 에 올라갔다
# (#357 — 모듈 쪽 `maven.deploy.skip` 은 이 플러그인의 속성이 아니라 **무효**였고, 게시된 pom 안에
# 그 무효한 속성이 그대로 들어 있었다). Central 은 철회 수단이 없으므로 그 좌표는 영구다.
# 지금 그것을 막는 것은 부모 POM 의 `<excludeArtifact>` **한 줄**뿐인데 보는 자리가 0 이었다.
#
# ⚠️ 리터럴로 박지 않는다 — 위험은 「지운다」보다 **「examples 를 개명한다」** 다. 플러그인은
# `excludeArtifacts.contains(artifact.getArtifactId())` 로 **맨 artifactId** 를 매칭하므로
# (`PublishMojo.java:374,409`), 모듈 이름이 바뀌면 제외가 조용히 안 걸리고 다음 릴리스에서
# examples 가 다시 Central 로 간다. 그래서 기대값을 examples POM 에서 **파생**한다.
_ex_pom="$_ab_root/java/keycloak-sdk-examples/pom.xml"
# ⚠️ 첫 `<artifactId>` 는 `<parent>` 의 것이다 — `</parent>` 뒤부터 읽는다.
_ex_id="$(sed -n '/<\/parent>/,$p' "$_ex_pom" 2>/dev/null | grep -oE '<artifactId>[^<]*' | head -1 | sed 's/.*>//')"
_ex_excl="$(grep -oE '<excludeArtifact>[^<]*' "$_ab_root/java/pom.xml" | sed 's/.*>//' | head -1)"
# ⚠️ 공허성 대조군은 **비었는가**만 본다 — 여기에 이름을 리터럴로 박으면 「모듈을 개명하고
# 제외도 함께 고친」 정상 변경까지 막는다(첫 구현이 그랬고 변이검증에서 발현했다).
# 이 가드가 겨누는 것은 이름이 아니라 **둘이 갈리는 것**이다.
assert_eq "nonempty" "$([ -n "$_ex_id" ] && echo nonempty || echo empty)" \
  "examples 모듈의 artifactId 를 읽지 못했다 — 추출이 비면 아래 대조가 공허해진다"
assert_eq "${_ex_id:-없음}" "${_ex_excl:-없음}" \
  "java/pom.xml 의 <excludeArtifact> 가 examples 모듈의 artifactId 와 다르다 — 제외가 매치되지 않아 examples 가 Central 에 게시된다(철회 불가)"

# ⚠️ `#372` 가 기각 레지스트리에 적은 되살릴 조건을 **기계로** 건다: examples 모듈에
# `<skipPublishing>` 을 거는 안을 채택하지 않은 근거가 「publish mojo 가 aggregator=false 이고
# examples 가 `<modules>` 의 **마지막**이라 번들 publish 자체가 그 모듈에서 일어난다」였다.
# 순서가 바뀌면 그 근거가 사라지므로 판정을 다시 해야 한다 — 산문이 아니라 여기서 운다.
_last_mod="$(sed -n '/<modules>/,/<\/modules>/p' "$_ab_root/java/pom.xml" | grep -oE '<module>[^<]*' | sed 's/.*>//' | tail -1)"
assert_eq "keycloak-sdk-examples" "${_last_mod:-없음}" \
  "java/pom.xml 의 <modules> 마지막이 examples 가 아니다 — <skipPublishing> 미채택 판정의 전제가 깨졌다(기각 레지스트리의 되살릴 조건)"

assert_report
