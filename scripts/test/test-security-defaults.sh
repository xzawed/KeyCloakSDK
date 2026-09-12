#!/usr/bin/env sh
# 보안 파라미터 기본값의 단일 진실 — 아홉 언어의 코드와 그것을 말하는 모든 소비자 문서가 같아야 한다.
#
# 왜 이 가드가 필요한가: JWKS 최소 재조회 간격은 **DoS 증폭 상한**이다. 위조 kid를 담은 토큰이
# 쏟아질 때 SDK가 IdP를 얼마나 자주 때리는지를 이 값 하나가 정한다. 2026-07-31에 아홉 언어를
# 30초로 정렬했는데(그 전에는 10·30·60 세 갈래였고, 같은 공격에 Ruby가 Python보다 IdP를 6배
# 자주 때렸다), **그 사실을 말하는 문서는 아무도 검사하지 않았다.**
#
# 실제로 그래서 깨져 있었다(2026-08-12 문서 감사): `ruby/README.ko.md`가 소비자에게 기본값을
# `10.0`이라고 알려주고 있었다 — 영문 미러는 30초라고 적는 그 자리에서. 3배 차이이고 하필
# 보안 파라미터다. 리포 전체에 이 불변식을 겨누는 가드는 0건이었다
# (`grep -rn "efetch" scripts/ .github/workflows/` → 0).
#
# ⚠️ 이 가드는 **두 축을 함께** 본다. 한쪽만 보면 조용히 공허해진다:
#   (1) 코드 축 — 아홉 언어의 config 기본값이 서로 같은가. 하나가 드리프트하면 문서가 전부
#       맞아도 언어 간 동작이 갈린다.
#   (2) 문서 축 — 그 값을 말하는 소비자 문서가 코드값과 같은가. 코드가 전부 같아도 문서가
#       틀리면 소비자는 틀린 값을 전제로 자기 rate-limit을 설계한다.
#
# ⚠️ **거버넌스·계획 문서는 스코프 밖이다.** `docs/governance/`와 남은 진행 계획은
# 소비자 문서가 아니라, 옛 값을 적어도 드리프트가 아니라 기록이다. 소비자가 복사해 가는
# 문서만 겨눈다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
# ⚠️ **루트는 덮어쓸 수 있어야 한다** — 아래 음성 대조군이 값 하나만 바꾼 TMP 트리를 가리켜
# 「추출기가 정말 파일을 읽는가」를 잰다. 이 변수가 고정이면 그 대조군을 쓸 수 없다.
ROOT="${SD_ROOT:-$DIR/../..}"

# ⚠️ `assert_ok`는 **명령만** 받는다(메시지 인자를 주면 그것까지 명령으로 해석해 실패한다).
# 메시지를 남기려면 "ok" 여부를 문자열로 만들어 `assert_eq`에 넘긴다.
ok_if() { if [ "$1" = 0 ]; then printf 'ok'; else printf '%s' "${2:-NOT-OK}"; fi; }

# ---------------------------------------------------------------------------
# 1) 코드 축 — 아홉 언어의 config 기본값
# ---------------------------------------------------------------------------
#
# ✅ **좁혔던 스코프는 Task D1에서 해소됐다(2026-08-13).** 예전에는 go `jwt.go`(60)·php
# `JwksStore`(60)·ruby `jwks_store.rb`(10.0)에 **2차 리터럴**이 남아 있었고, 이 가드는 그 셋을
# 스코프 밖에 두었다(함께 검사하면 미해결 결함 때문에 영구 RED가 되어 아무도 켜두지 않게 되므로).
# 지금은 셋 다 config의 상수를 참조하므로 리터럴이 하나뿐이고, **2차 리터럴이 다시 생기는 것을
# 아래 3-절이 막는다.**
#
# ⚠️ php·ruby의 2차 자리는 cosmetic이 아니었다 — 두 클래스 다 public 생성자라 소비자가 파사드를
# 거치지 않고 직접 생성할 수 있었고, ruby는 그 경로에서 10초를 받아 문서가 말하는 30초보다
# **IdP를 3배 자주** 때렸다(한글 README도 그 10.0을 옮겨 적고 있었다). go만 비수출이라 도달 불가였다.
sd_default() { # $1=언어 → 기본값(정규화 전)
  case "$1" in
    java)   sed -n 's/.*jwksMinRefetch *= *Duration\.ofSeconds(\([0-9][0-9.]*\)).*/\1/p' \
              "$ROOT/java/keycloak-sdk-core/src/main/java/io/github/xzawed/keycloak/core/KeycloakConfig.java" | head -1 ;;
    python) sed -n 's/.*jwks_min_refetch_seconds: *float *= *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/python/src/keycloak_sdk/config.py" | head -1 ;;
    node)   sed -n 's/.*jwksMinRefetchSeconds: *input\.jwksMinRefetchSeconds *?? *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/node/src/config.ts" | head -1 ;;
    go)     sed -n 's/.*defaultJwksMinRefetchSecs *int64 *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/go/config.go" | head -1 ;;
    dotnet) sed -n 's/.*RefreshIntervalSeconds *{ *get; *init; *} *= *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/dotnet/src/Xzawed.Keycloak.Sdk/JwtValidator.cs" | head -1 ;;
    php)    sed -n 's/.*DEFAULT_JWKS_MIN_REFETCH_SECONDS *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/php/src/KeycloakConfig.php" | head -1 ;;
    rust)   sed -n 's/.*jwks_min_refetch_secs: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/rust/src/config.rs" | head -1 ;;
    ruby)   sed -n 's/.*DEFAULT_JWKS_MIN_REFETCH *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/ruby/lib/keycloak_sdk/config.rb" | head -1 ;;
    kotlin) sed -n 's/.*jwksMinRefetch: *Duration *= *Duration\.ofSeconds(\([0-9][0-9.]*\)).*/\1/p' \
              "$ROOT/kotlin/src/main/kotlin/io/github/xzawed/keycloak/config.kt" | head -1 ;;
  esac
}
# `30.0`·`30` 은 같은 값이다 — 언어마다 float/int 관용이 달라 표기만 갈린다.
sd_norm() { printf '%s' "$1" | sed 's/\.0*$//'; }

# clock skew — JWT `exp`/`nbf` 검증의 시계 오차 허용치. **이것도 아홉 언어 공동 불변식이다**
# (2026-08-13 결정). 한 언어만 커지면 **그 언어에서만 만료된 토큰이 더 오래 통과한다** — JWKS와
# 같은 계급의 보안 파라미터인데 가드가 없어서, JWKS가 10/30/60으로 갈렸던 것과 똑같은 조건에
# 놓여 있었다(측정 시점에는 아홉 전부 30으로 우연히 정렬돼 있었다).
sd_skew() { # $1=언어 → clock skew 기본값
  case "$1" in
    java)   sed -n 's/.*clockSkew *= *Duration\.ofSeconds(\([0-9][0-9.]*\)).*/\1/p' \
              "$ROOT/java/keycloak-sdk-core/src/main/java/io/github/xzawed/keycloak/core/KeycloakConfig.java" | head -1 ;;
    python) sed -n 's/.*clock_skew: *float *= *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/python/src/keycloak_sdk/config.py" | head -1 ;;
    node)   sed -n 's/.*clockSkewSeconds: *input\.clockSkewSeconds *?? *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/node/src/config.ts" | head -1 ;;
    go)     sed -n 's/.*c\.ClockSkew *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/go/config.go" | head -1 ;;
    dotnet) sed -n 's/.*ClockSkewSeconds *{ *get; *init; *} *= *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/dotnet/src/Xzawed.Keycloak.Sdk/JwtValidator.cs" | head -1 ;;
    php)    sed -n 's/.*\$clockSkew *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/php/src/KeycloakConfig.php" | head -1 ;;
    rust)   sed -n 's/.*clock_skew: *\([0-9][0-9.]*\).*/\1/p' "$ROOT/rust/src/config.rs" | head -1 ;;
    ruby)   sed -n 's/.*DEFAULT_CLOCK_SKEW *= *\([0-9][0-9.]*\).*/\1/p' "$ROOT/ruby/lib/keycloak_sdk/config.rb" | head -1 ;;
    kotlin) sed -n 's/.*clockSkew: *Duration *= *Duration\.ofSeconds(\([0-9][0-9.]*\)).*/\1/p' \
              "$ROOT/kotlin/src/main/kotlin/io/github/xzawed/keycloak/config.kt" | head -1 ;;
  esac
}

SD_LANGS='java python node go dotnet php rust ruby kotlin'

# ---------------------------------------------------------------------------
# 0) 언어 집합 축 — 손 목록이 트리보다 짧아지는 것을 막는다
# ---------------------------------------------------------------------------
#
# 왜 필요한가: 아래 축들이 전부 `SD_LANGS` 를 돈다. 그런데 그 목록은 **손으로 적혀 있고**,
# 그것을 지키던 대조군은 `assert_eq "9" "$_seen"` 이라 `_seen` 이 `SD_LANGS` 자신을 센 수다 —
# **9 == 9 가 구조적으로 보장**돼 열 번째 언어를 잡을 수 없었다(실측 2026-09-12: 최상위에
# 빌드파일을 가진 디렉터리를 하나 주입해도 `244 passed, 0 failed`). 그 언어는 보안 기본값
# 커버리지가 0 인 채로 들어오고 아무도 모른다.
#
# ⚠️ 파생 원천은 **최상위 디렉터리 중 자기 루트에 빌드 매니페스트를 가진 것**이다.
# 다른 후보는 전부 required 체크에서 오탐을 낸다(셋 다 실측):
#   · `.claude/rules/*.md` — 이미 **비언어 둘**을 얻었다(`ci.md` 2026-08-06 · `security.md`
#     2026-08-17, 삭제 이력 0). 다음 횡단 규칙 파일 하나가 모든 PR 을 막는다.
#   · `harness/apps/*/` — 플레이북 Stage 5 라 **구조적으로 늦다**. 아홉 전부 SDK 디렉터리가
#     먼저였다(kotlin 하루 · java 사흘).
#   · `check-versions.mjs --list` — 설계상 **7** 이다(go·php 는 태그가 SSOT). 오늘 main 을 빨갛게 한다.
#
# **오탐 실측**: 이 파생을 `main` 이력 전수에 돌렸다 — 커밋 475 중 `SD_LANGS` 가 존재한
# **281 건에서 불일치 0**(kotlin 이 아홉째로 들어온 구간 포함). 재현:
# `sh scripts/measure-lang-universe-fp.sh`
#
# ⚠️ 잔여 **오탐**은 하나다 — 최상위에 위 매니페스트를 가진 **비언어** 디렉터리가 생기는 것
# (`website/package.json` 류). 그 PR 이 같은 커밋에서 `SD_LANGS` 를 늘리면 된다.
# ⚠️ 잔여 **거짓음성**도 적어 둔다 — 매니페스트가 이 목록에 없는 언어(Swift `Package.swift` ·
# Elixir `mix.exs`)는 못 잡는다. 목록을 늘리는 것이 그 언어를 들이는 작업의 일부다.
SD_MANIFEST='pom\.xml|pyproject\.toml|package\.json|go\.mod|composer\.json|Cargo\.toml|build\.gradle\.kts|[^/]+\.gemspec|[^/]+\.sln'
sd_tree_langs() {
  ( cd "$ROOT" && git ls-files ) | sed -n 's#^\([^/]*\)/.*#\1#p' | sort -u | while read -r d; do
    if ( cd "$ROOT" && git ls-files "$d/" ) | grep -qE "^$d/($SD_MANIFEST)\$"; then printf '%s\n' "$d"; fi
  done | sort | tr '\n' ' '
}
sd_sorted() { printf '%s' "$1" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }

_sd_tree="$(sd_tree_langs)"
# 공허 방어 — 파생이 0 건이면 「불일치 없음」이 통과처럼 보인다(git 이 없는 트리·글롭 파손).
assert_eq "ok" "$(ok_if "$([ -n "$_sd_tree" ] && echo 0 || echo 1)" 'EMPTY')" \
  "[언어집합] 트리에서 언어를 하나도 파생하지 못했다 — 이 축이 조용히 공허해진다"
assert_eq "$(sd_sorted "$_sd_tree")" "$(sd_sorted "$SD_LANGS")" \
  "[언어집합] SD_LANGS 가 트리와 다르다 — 언어가 들고 났는데 이 파일의 손 목록이 안 따라왔다(아래 축 전부가 그 언어를 건너뛴다)"

# ⚠️ 부분집합만 본다 — `SD_CAP_LANGS`·`SD_BACKOFF_LANGS` 는 **의도적으로 일곱**이다
# (java·kotlin 은 JWKS fetch 를 Nimbus 가 소유해 이 축의 대상이 아니다). 전체집합과 같기를
# 요구하면 그 설계를 깨뜨린다. 여기서 잡는 것은 **오타·유령 이름**이다.

# ⚠️ **음성 대조군 — 파생이 트리를 실제로 읽는가.** 위 단언은 「지금 일치한다」만 본다. 그 형태는
# **파생이 no-op 이어도 통과한다** — `sd_tree_langs() { printf '%s ' java python … kotlin; }` 로
# 바꾸면 정답 상수라 초록이고, 그러면 이 축은 있으나 마나가 된다. 실측으로 확인했다
# (`scripts/probe.sh` → **SILENT**, 즉 진짜 구멍이었다). 그래서 **언어 집합이 다른** 트리를
# 만들어 파생이 그 다른 답을 내는지 본다.
# ⚠️ 값 하나짜리 픽스처가 아니라 git 저장소여야 한다 — 파생이 `git ls-files` 로 돌기 때문이다.
sd_universe_negative_control() {
  _uc_tmp="$(mktemp -d)"
  ( cd "$_uc_tmp" \
    && git init -q -b main . >/dev/null 2>&1 \
    && mkdir -p alpha beta notalang \
    && : > alpha/Cargo.toml && : > beta/composer.json && : > notalang/README.md \
    && git add -A >/dev/null 2>&1 ) || { rm -rf "$_uc_tmp"; return 0; }
  _uc_got="$(ROOT="$_uc_tmp" sd_tree_langs)"
  rm -rf "$_uc_tmp"
  # 기대: 매니페스트를 가진 둘만. `notalang` 은 매니페스트가 없으므로 들어오면 안 된다
  # (그 한 자리가 「최상위 디렉터리를 전부 언어로 읽는다」와 이 파생을 가른다).
  assert_eq "alpha beta " "$_uc_got" \
    "[음성대조·언어집합] 언어가 다른 트리에서도 같은 답을 낸다 — 파생이 트리를 안 읽는다(no-op)"
}
sd_universe_negative_control
sd_subset_of_langs() { # $1=라벨 $2=목록
  _ss_bad=''
  for _l in $2; do
    case " $SD_LANGS " in *" $_l "*) ;; *) _ss_bad="$_ss_bad $_l" ;; esac
  done
  assert_eq "" "$_ss_bad" "[언어집합] $1 에 SD_LANGS 에 없는 이름이 있다 —$_ss_bad"
}

# 코드 축을 파라미터별로 돈다. 결과 기대값은 `SD_EXPECT`에 남긴다(문서 축이 그걸 쓴다).
sd_code_axis() { # $1=라벨 $2=추출 함수명
  SD_EXPECT=''
  _seen=0
  for L in $SD_LANGS; do
    _raw="$("$2" "$L" || true)"
    # ⚠️ 추출 실패를 통과로 읽지 않는다 — 파일이 옮겨지거나 선언 표기가 바뀌면 sed가 빈 문자열을
    # 내는데, 그걸 넘기면 이 가드는 **아홉 언어를 하나도 안 보면서 초록**이 된다(이 저장소가
    # 반복해서 겪은 부류).
    _has=1; [ -n "$_raw" ] && _has=0
    assert_eq "ok" "$(ok_if "$_has" MISSING)" \
      "[$1] $L 의 기본값을 소스에서 추출하지 못했다 — 선언 표기가 바뀌었나?"
    [ -n "$_raw" ] || continue
    _v="$(sd_norm "$_raw")"
    _seen=$((_seen + 1))
    if [ -z "$SD_EXPECT" ]; then
      SD_EXPECT="$_v"
    else
      assert_eq "$SD_EXPECT" "$_v" \
        "[$1] $L 의 기본값이 다른 언어와 다르다 — 아홉이 함께 움직여야 하는 값이다"
    fi
  done
  # 대조군 — 위 루프가 실제로 아홉 언어를 돌았는지. `SD_LANGS`가 비거나 경로 규칙이 바뀌면
  # 어서션이 0건 실행되고 이 테스트는 조용히 통과한다.
  assert_eq "9" "$_seen" "[$1] 기본값을 읽은 언어 수가 9가 아니다 — 추출 표가 낡았나?"
}

sd_code_axis "JWKS 재조회" sd_default
sd_expect="$SD_EXPECT"
sd_code_axis "clock skew" sd_skew

# ---------------------------------------------------------------------------
# 1b) JWKS 응답 **크기 상한** — 같은 계급의 DoS 파라미터인데 축이 없었다
# ---------------------------------------------------------------------------
#
# 상한이 없으면 손상된 IdP 하나가 검증 경로를 메모리로 죽인다. 값 51200 은 우리가 고른 수가
# 아니라 Nimbus `JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT` 이고, 자체 fetch 를 하는 언어들이
# 그 수를 따라간다.
#
# ⚠️ **이 축의 스코프는 아홉이 아니다 — 그 이유를 여기 적는다**(적지 않으면 다음 세션이
# 「아홉을 본다」로 잘못 읽는다):
#   · 리터럴을 **자기 소스에** 선언하는 일곱 = go · rust · php · ruby · node · dotnet · python
#     → 값까지 대조한다.
#     ⚠️ node 는 `jose` 에 위임하지만 **jose 에 상한이 없어**(6.2.12 실측: `fetchJwks` 가
#     `response.json()` 뿐) `[customFetch]` 이음매로 우리가 건다 — 그래서 값이 우리 소스에 있다.
#   · java · kotlin 은 Nimbus 상수를 **심볼로 참조**한다(`NoRedirectResourceRetriever`). 리터럴이
#     없는 것이 옳으므로 값이 아니라 **참조의 존재**를 본다 — 그 인자를 빼면 Nimbus 가 상한을
#     지운다는 것이 #400 의 실측이다.
#   · **python 도 닫혔다**(2026-09-12) — 상류 `certs()` 에는 상한을 끼울 이음매가 **없다**
#     (`raw_get` 이 `**kwargs` 를 `params=` 로 보내 `stream=True` 가 쿼리 파라미터가 된다).
#     그래서 `_internal/jwks_fetch.py` 가 JWKS **요청 하나만** 직접 스트리밍 GET 한다 —
#     세션 전체에 걸면 token·introspect·logout 까지 묶이고 역할 많은 토큰은 정당하게 크다.
#     ⚠️ 그 모듈은 `requests`/`httpx` 예외를 **스스로** SDK 타입으로 번역한다: `_wrap` 은
#     상류 `KeycloakError` 하나만 잡아서, 직접 HTTP 를 부르면 하위 타입이 그대로 샌다(§4).
#   · **dotnet 은 닫혔다**(2026-09-11) — `Microsoft.IdentityModel` 이 컴파일된 패키지라 내부
#     상한 여부는 **여전히 미측정**이지만, 그것과 무관하게 우리가 `IDocumentRetriever` 를
#     직접 구현해 상한을 건다(`BoundedDocumentRetriever`). ⚠️ `MaxResponseContentBufferSize`
#     를 쓰지 않은 이유: 그 `HttpClient` 은 `AuthClient` 와 **공유**라(`KeycloakClient.cs:10`)
#     토큰·introspect 응답까지 함께 묶인다 — 역할이 많은 액세스 토큰은 정당하게 크다.
sd_jwks_cap() { # $1=언어 → 상한 리터럴(정규화 전)
  case "$1" in
    go)   sed -n 's/.*jwksMaxBytes *= *\([0-9_]*\).*/\1/p' "$ROOT/go/jwt.go" | head -1 ;;
    rust) sed -n 's/.*JWKS_MAX_BYTES: *usize *= *\([0-9_]*\).*/\1/p' "$ROOT/rust/src/jwks.rs" | head -1 ;;
    php)  sed -n 's/.*const JWKS_MAX_BYTES *= *\([0-9_]*\).*/\1/p' "$ROOT/php/src/Jwks/JwksStore.php" | head -1 ;;
    ruby) sed -n 's/.*JWKS_MAX_BYTES *= *\([0-9_]*\).*/\1/p' "$ROOT/ruby/lib/keycloak_sdk/jwks_store.rb" | head -1 ;;
    node) sed -n 's/.*JWKS_MAX_BYTES *= *\([0-9_]*\).*/\1/p' "$ROOT/node/src/jwt.ts" | head -1 ;;
    dotnet) sed -n 's/.*const int MaxBytes *= *\([0-9_]*\).*/\1/p' \
              "$ROOT/dotnet/src/Xzawed.Keycloak.Sdk/BoundedDocumentRetriever.cs" | head -1 ;;
    python) sed -n 's/.*JWKS_MAX_BYTES *= *\([0-9_]*\).*/\1/p' \
              "$ROOT/python/src/keycloak_sdk/_internal/jwks_fetch.py" | head -1 ;;
  esac
}

SD_CAP_LANGS='go rust php ruby node dotnet python'
sd_subset_of_langs "SD_CAP_LANGS" "$SD_CAP_LANGS"
sd_cap_expect=''
sd_cap_seen=0
for L in $SD_CAP_LANGS; do
  # ruby 는 `51_200` 으로 적는다 — 자릿수 구분자는 표기일 뿐이므로 지운 뒤 비교한다.
  _raw="$(sd_jwks_cap "$L" | tr -d '_' || true)"
  # ⚠️ 추출 실패를 통과로 읽지 않는다 — 선언 표기가 바뀌면 sed 가 빈 문자열을 내고, 그걸
  # 넘기면 이 축은 **아무것도 안 보면서 초록**이 된다.
  _has=1; [ -n "$_raw" ] && _has=0
  assert_eq "ok" "$(ok_if "$_has" MISSING)" \
    "[JWKS 크기상한] $L 의 상한을 소스에서 추출하지 못했다 — 선언이 지워졌거나 표기가 바뀌었다"
  [ -n "$_raw" ] || continue
  sd_cap_seen=$((sd_cap_seen + 1))
  if [ -z "$sd_cap_expect" ]; then
    sd_cap_expect="$_raw"
  else
    assert_eq "$sd_cap_expect" "$_raw" \
      "[JWKS 크기상한] $L 의 상한이 다른 언어와 다르다 — 여섯이 함께 움직여야 하는 값이다"
  fi
done
# 대조군 — 위 루프가 실제로 여섯을 돌았는지. 목록이 비면 어서션이 0건 실행되고 조용히 통과한다.
assert_eq "7" "$sd_cap_seen" "[JWKS 크기상한] 상한을 읽은 언어 수가 7이 아니다 — 추출 표가 낡았나?"
# 값은 Nimbus 의 기본 상한이다. 자매 JVM 둘이 그것을 **심볼로** 참조하므로, 여기서만 수를 고정한다.
assert_eq "51200" "$sd_cap_expect" "[JWKS 크기상한] 51200(Nimbus DEFAULT_HTTP_SIZE_LIMIT)이 아니다"

# JVM 둘 — 리터럴이 아니라 **참조의 존재**를 본다. 이 인자를 빼면 `JWKSourceBuilder` 가 자기
# 리트리버를 만들며 상한을 지운다(#400 의 바이트코드 실측).
for _f in \
  "java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/NoRedirectResourceRetriever.java" \
  "kotlin/src/main/kotlin/io/github/xzawed/keycloak/NoRedirectResourceRetriever.kt"
do
  _hits="$(grep -c 'DEFAULT_HTTP_SIZE_LIMIT' "$ROOT/$_f" 2>/dev/null || printf '0')"
  assert_eq "ok" "$(ok_if "$([ "$_hits" -ge 1 ] && printf 0 || printf 1)" MISSING)" \
    "[JWKS 크기상한] $_f 가 JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT 을 더 이상 참조하지 않는다"
done

# ⚠️ **둘째 정의 자리.** 위 축은 언어당 한 곳만 읽는데, 두 언어는 같은 파라미터를 **두 곳**에
# 선언한다 — 그리고 dotnet 은 위 축이 읽는 쪽이 **소비자가 받는 값이 아니다**:
#   dotnet  JwtValidator.cs(위 축) + KeycloakConfig.cs. 파사드가 `ClockSkewSeconds = cfg.ClockSkewSeconds`
#           로 넘기므로(KeycloakClient.cs) 소비자 값은 **KeycloakConfig 쪽**이다.
#   python  config.py(위 축) + _internal/jwt.py 의 파라미터 기본값.
# 실측 2026-08-29: KeycloakConfig.cs 를 30 → 300 으로 바꿔도 이 가드는 **103/0 으로 통과했다**
# (dotnet 단위테스트가 대신 잡았다). 값이 갈리는 자리를 가드가 안 보면 그 초록은 공허하다.
sd_skew_secondary() { # $1=언어 → 둘째 정의 자리의 clock skew (해당 없으면 빈 문자열)
  case "$1" in
    dotnet) sed -n 's/.*ClockSkewSeconds *{ *get; *init; *} *= *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/dotnet/src/Xzawed.Keycloak.Sdk/KeycloakConfig.cs" | head -1 ;;
    python) sed -n 's/.*clock_skew: *float *= *\([0-9][0-9.]*\).*/\1/p' \
              "$ROOT/python/src/keycloak_sdk/_internal/jwt.py" | head -1 ;;
  esac
}

_sec=0
for L in dotnet python; do
  _raw="$(sd_skew_secondary "$L" || true)"
  _has=1; [ -n "$_raw" ] && _has=0
  assert_eq "ok" "$(ok_if "$_has" MISSING)" \
    "[clock skew·둘째 자리] $L 의 둘째 정의를 추출하지 못했다 — 파일이 옮겨졌거나 표기가 바뀌었나?"
  [ -n "$_raw" ] || continue
  _sec=$((_sec + 1))
  assert_eq "$SD_EXPECT" "$(sd_norm "$_raw")" \
    "[clock skew·둘째 자리] $L 의 둘째 정의가 첫째와 다르다 — 소비자가 받는 값이 갈렸다"
done
# 대조군 — 위 루프가 실제로 둘을 돌았는지. 표가 낡으면 0건 실행되고 조용히 통과한다.
assert_eq "2" "$_sec" "[clock skew·둘째 자리] 읽은 둘째 자리 수가 2가 아니다 — 추출 표가 낡았나?"
sd_skew_expect="$SD_EXPECT"

# ⚠️ **일치만으로는 부족하다 — 값 자체를 핀한다.** 위 축은 "아홉이 서로 같은가"만 본다. 그래서
# 아홉이 **함께** 60으로 움직이면 이 가드는 초록이고, 문서 축도 코드에서 뽑은 값을 쓰므로 함께
# 따라간다. 즉 종전에는 리포지토리 어디에서도 `30`이라는 숫자를 지키는 곳이 없었다(리터럴 30은
# 주석에만 있었다). CLAUDE.md 는 "아홉 전부 30초"라 말하며 **이 파일을 가드로 지목**하고 있었다.
#
# 30 은 측정이 아니라 **정책 제약**이다 — Nimbus 의 `DEFAULT_RATE_LIMIT_MIN_INTERVAL` 과 같게
# 고른 보안 결정이고 근거는 `.claude/rules/security.md` 가 소유한다. 그러므로 규칙이 옳고
# 가드가 그것을 집행해야 한다. 값을 바꾸려면 **이 줄과 그 문서를 함께** 고쳐야 한다.
SD_POLICY=30
assert_eq "$SD_POLICY" "$sd_expect" \
  "JWKS 재조회 기본값이 정책값($SD_POLICY)과 다르다 — 아홉이 함께 움직였어도 정책이 바뀐 것은 아니다"
assert_eq "$SD_POLICY" "$sd_skew_expect" \
  "clock skew 기본값이 정책값($SD_POLICY)과 다르다 — 아홉이 함께 움직였어도 정책이 바뀐 것은 아니다"

# ---------------------------------------------------------------------------
# 1b) nonce 축 — 아홉 언어 auth 소스에 생성·검증이 있는가
# ---------------------------------------------------------------------------
#
# JWKS/clock-skew는 **숫자 기본값**이라 위 1절이 잡는다. nonce는 값이 아니라 **존재**다.
# 이슈 #188: PHP `src/`에 nonce 0건인데 README가 "아홉 전부"라고 했고, 이 파일이
# 그 주장을 세지 않아 문서만 정직해지고 코드 갭은 남았다. 이 축은 아홉 auth 파일이
# (a) 인가 요청에 nonce를 만들고 (b) exchange에서 id_token nonce를 검증하는지 본다.
# 한 언어라도 빠지면 실패한다. `_seen`이 9가 아니면 표가 낡은 것이다.
sd_nonce_file() {
  case "$1" in
    java)   printf '%s' 'java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java' ;;
    python) printf '%s' 'python/src/keycloak_sdk/auth.py' ;;
    node)   printf '%s' 'node/src/auth.ts' ;;
    go)     printf '%s' 'go/auth.go' ;;
    dotnet) printf '%s' 'dotnet/src/Xzawed.Keycloak.Sdk/AuthClient.cs' ;;
    php)    printf '%s' 'php/src/AuthClient.php' ;;
    rust)   printf '%s' 'rust/src/auth.rs' ;;
    ruby)   printf '%s' 'ruby/lib/keycloak_sdk/auth_client.rb' ;;
    kotlin) printf '%s' 'kotlin/src/main/kotlin/io/github/xzawed/keycloak/auth.kt' ;;
  esac
}
# 생성 앵커 — "인가 URL에 nonce를 싣는 줄". 주석만 남기고 구현을 지우면 실패해야 한다.
sd_nonce_create() {
  case "$1" in
    java)   printf '%s' 'Nonce nonce = new Nonce()' ;;
    python) printf '%s' 'nonce = secrets.token_urlsafe' ;;
    node)   printf '%s' "searchParams.set('nonce'" ;;
    go)     printf '%s' 'SetAuthURLParam("nonce"' ;;
    dotnet) printf '%s' 'var nonce = CryptoRandom.CreateUniqueId' ;;
    php)    printf '%s' "'nonce' => \$nonce" ;;
    rust)   printf '%s' 'Nonce::new_random' ;;
    ruby)   printf '%s' 'nonce: SecureRandom.urlsafe_base64(24)' ;;
    kotlin) printf '%s' 'val nonce = Nonce()' ;;
  esac
}
# 검증 앵커 — exchange가 id_token nonce를 대조하는 줄.
sd_nonce_verify() {
  case "$1" in
    java)   printf '%s' 'requireValidNonce' ;;
    python) printf '%s' '_verify_nonce' ;;
    node)   printf '%s' 'expectedNonce' ;;
    go)     printf '%s' 'verifyNonce' ;;
    dotnet) printf '%s' 'id_token nonce mismatch' ;;
    php)    printf '%s' 'requireValidNonce' ;;
    rust)   printf '%s' 'async fn verify_nonce(&self' ;;
    ruby)   printf '%s' 'verify_nonce!' ;;
    kotlin) printf '%s' 'unexpected nonce' ;;
  esac
}

_nonce_seen=0
for L in $SD_LANGS; do
  _nf="$(sd_nonce_file "$L")"
  _exists=1; [ -f "$ROOT/$_nf" ] && _exists=0
  assert_eq "ok" "$(ok_if "$_exists" MISSING)" "[nonce] $L auth 파일이 없다($_nf)"
  [ -f "$ROOT/$_nf" ] || continue
  _cp="$(sd_nonce_create "$L")"
  _vp="$(sd_nonce_verify "$L")"
  _hasc=1; grep -qF -- "$_cp" "$ROOT/$_nf" && _hasc=0
  assert_eq "ok" "$(ok_if "$_hasc" MISSING)" \
    "[nonce] $L 인가 요청에 nonce 생성이 없다 — 기대: $_cp"
  _hasv=1; grep -qF -- "$_vp" "$ROOT/$_nf" && _hasv=0
  assert_eq "ok" "$(ok_if "$_hasv" MISSING)" \
    "[nonce] $L exchange nonce 검증이 없다 — 기대: $_vp"
  _nonce_seen=$((_nonce_seen + 1))
done
assert_eq "9" "$_nonce_seen" "[nonce] 훑은 언어 수가 9가 아니다 — 추출 표가 낡았나?"

# ---------------------------------------------------------------------------
# 1b2) 콜드 캐시 백오프 축 — 실패한 JWKS fetch 를 상한하는 장치가 일곱에 다 있는가
# ---------------------------------------------------------------------------
#
# 1절의 30초는 **캐시가 찬 뒤**의 미해결 kid 홍수만 막는다. 캐시가 비어 있고 fetch 가 계속
# 실패하면 그 게이트에 닿지도 못해, 실측상 20회 검증이 IdP 요청 20건을 그대로 냈다
# (2026-09-04 · 7개 언어 동일 · dotnet 은 40). 그래서 **별도 축**이 필요하다.
#
# ⚠️ 이 축은 **일곱**이다(java·kotlin 제외 — Nimbus 가 그들의 fetch 를 소유해 이 자리가 없다).
# `_seen`이 7이 아니면 표가 낡은 것이다. 언어별 동작은 각 언어 단위테스트가 증명하고, 여기서는
# **대칭**만 본다 — 한 언어에서 장치를 지우면 그 언어 CI 와 이 가드가 함께 운다.
SD_BACKOFF_LANGS="python node go dotnet php rust ruby"
sd_subset_of_langs "SD_BACKOFF_LANGS" "$SD_BACKOFF_LANGS"

sd_backoff_file() {
  case "$1" in
    python) printf '%s' 'python/src/keycloak_sdk/_internal/backoff.py' ;;
    node)   printf '%s' 'node/src/jwt.ts' ;;
    go)     printf '%s' 'go/jwt.go' ;;
    dotnet) printf '%s' 'dotnet/src/Xzawed.Keycloak.Sdk/BackoffConfigurationManager.cs' ;;
    php)    printf '%s' 'php/src/Jwks/FailureBackoff.php' ;;
    rust)   printf '%s' 'rust/src/jwks.rs' ;;
    ruby)   printf '%s' 'ruby/lib/keycloak_sdk/jwks_store.rb' ;;
  esac
}
# 상한(cap) 앵커 — 지우면 백오프가 무한히 자라거나 사라진다. 값 자체가 계약이라 리터럴로 겨눈다.
sd_backoff_cap() {
  case "$1" in
    python) printf '%s' 'CAP_SECONDS = 5.0' ;;
    node)   printf '%s' 'FAILURE_BACKOFF_CAP_MS = 5_000' ;;
    go)     printf '%s' 'jwksFailureBackoffCap  = 5 * time.Second' ;;
    dotnet) printf '%s' 'BackoffCap = TimeSpan.FromSeconds(5)' ;;
    php)    printf '%s' 'CAP_SECONDS  = 5.0' ;;
    rust)   printf '%s' 'FAILURE_BACKOFF_CAP: Duration = Duration::from_secs(5)' ;;
    ruby)   printf '%s' 'FAILURE_BACKOFF_CAP  = 5.0' ;;
  esac
}
# 게이트 앵커 — 「창 안에서는 IdP 를 때리지 않고 즉시 실패」를 실제로 하는 줄.
sd_backoff_gate() {
  case "$1" in
    python) printf '%s' 'def remaining(self)' ;;
    node)   printf '%s' 'const remainingMs =' ;;
    go)     printf '%s' 'func (v *Validator) backoffRemaining(' ;;
    dotnet) printf '%s' 'private TimeSpan BackoffRemaining(' ;;
    php)    printf '%s' 'public function remaining(): float' ;;
    rust)   printf '%s' 'fn backoff_remaining(' ;;
    ruby)   printf '%s' 'def backoff_remaining' ;;
  esac
}

_backoff_seen=0
for L in $SD_BACKOFF_LANGS; do
  _bf="$(sd_backoff_file "$L")"
  _exists=1; [ -f "$ROOT/$_bf" ] && _exists=0
  assert_eq "ok" "$(ok_if "$_exists" MISSING)" "[backoff] $L 백오프 파일이 없다($_bf)"
  [ -f "$ROOT/$_bf" ] || continue
  _cp="$(sd_backoff_cap "$L")"
  _gp="$(sd_backoff_gate "$L")"
  _hasc=1; grep -qF -- "$_cp" "$ROOT/$_bf" && _hasc=0
  assert_eq "ok" "$(ok_if "$_hasc" MISSING)" \
    "[backoff] $L 실패 백오프 상한이 없다 — 기대: $_cp"
  _hasg=1; grep -qF -- "$_gp" "$ROOT/$_bf" && _hasg=0
  assert_eq "ok" "$(ok_if "$_hasg" MISSING)" \
    "[backoff] $L 백오프 잔여시간 계산이 없다 — 기대: $_gp"
  _backoff_seen=$((_backoff_seen + 1))
done
assert_eq "7" "$_backoff_seen" "[backoff] 훑은 언어 수가 7이 아니다 — 추출 표가 낡았나?"

# ---------------------------------------------------------------------------
# 1c) 마스킹 축 — 아홉 언어의 **바닥 계약**이 살아있는가
# ---------------------------------------------------------------------------
#
# 계약(교차언어): **비밀 보유 타입은 그 언어의 기본 문자열/디버그 표현에서 비밀을 `***` 로 낸다.**
# 이것이 아홉 전부에서 참이면서 기계로 강제할 수 있는 **유일한 바닥**이다. 「JSON 도 마스킹한다」는
# 계약이 될 수 없다 — Rust 는 Serialize 를 derive 하지 않아 그 경로가 아예 없고, Go 에 MarshalJSON 을
# 달면 소비자의 세션·캐시 왕복이 조용히 마스킹된 값으로 저장된다(.NET 이 converter 의 Read 를
# throw 로 막아야 했던 이유). 바닥 위의 훅(toJSON·JsonSerializable·LogValuer)은 언어마다 있고
# 없고가 갈리므로 여기서 강제하지 않는다.
#
# ⚠️ **훅의 존재만 세면 이 축은 헛돈다.** 훅이 남은 채 본문이 `%+v` 덤프로 바뀌면 grep 은 그대로
# 통과한다. 그래서 언어마다 **둘**을 본다 — (a) 구현 훅이 있고 (b) **행위 카나리아 테스트**가
# 있다. (b) 가 실제 마스킹을 단언하는 자리이고, 각 언어 CI 가 그것을 돌린다. 이 축은 그 테스트가
# **삭제되지 않았음**을 보장한다.
#
# 실측 배경(2026-09-03): 이 축을 세우기 전 go 는 바닥을 깨고 있었다 — `TokenSet.String()` 이
# 포인터 리시버라 **값은 Stringer 가 아니었고**, `AuthorizationRequest` 에는 String() 자체가
# 없었다(둘 다 `fmt.Printf("%v", …)` 로 원문 노출, 프로브로 확인).
sd_mask_src() {
  case "$1" in
    java)   printf '%s' 'java/keycloak-sdk-core/src/main/java/io/github/xzawed/keycloak/core/TokenSet.java' ;;
    kotlin) printf '%s' 'kotlin/src/main/kotlin/io/github/xzawed/keycloak/tokens.kt' ;;
    python) printf '%s' 'python/src/keycloak_sdk/tokens.py' ;;
    node)   printf '%s' 'node/src/tokens.ts' ;;
    go)     printf '%s' 'go/tokens.go' ;;
    dotnet) printf '%s' 'dotnet/src/Xzawed.Keycloak.Sdk/Tokens.cs' ;;
    php)    printf '%s' 'php/src/Token/TokenSet.php' ;;
    rust)   printf '%s' 'rust/src/tokens.rs' ;;
    ruby)   printf '%s' 'ruby/lib/keycloak_sdk/tokens.rb' ;;
  esac
}
# 구현 훅 앵커 — 그 언어에서 `fmt`/문자열화가 타는 자리.
sd_mask_hook() {
  case "$1" in
    java)   printf '%s' 'public String toString()' ;;
    kotlin) printf '%s' 'override fun toString()' ;;
    python) printf '%s' '__repr__' ;;
    node)   printf '%s' 'toString(): string' ;;
    # ⚠️ 값 리시버여야 한다 — 포인터 리시버면 값이 Stringer 가 아니어서 필드가 그대로 찍힌다.
    go)     printf '%s' 'func (t TokenSet) String() string' ;;
    dotnet) printf '%s' 'public override string ToString()' ;;
    php)    printf '%s' 'public function __toString()' ;;
    rust)   printf '%s' 'impl std::fmt::Debug for TokenSet' ;;
    ruby)   printf '%s' 'def inspect' ;;
  esac
}
# 행위 카나리아 테스트 파일 — `TokenSet` 의 **기본 문자열/디버그 표현**이 비밀을 가리는지
# 실행해서 단언하는 자리.
#
# ⚠️ **여섯 언어가 엉뚱한 파일을 가리키고 있었다**(실측 2026-09-10). kotlin·python·node·dotnet·
# php·ruby 가 `Masking*` 파일을 가리켰는데 그 파일들이 단언하는 것은 `mask()` **헬퍼**이거나
# `AuthorizationRequest` 이지 `TokenSet` 의 기본 표현이 아니다. 앵커도 그냥 `***` 였으므로
# **그 파일의 아무 마스킹 테스트나** 만족시켰다 — `TokenSet` 카나리아를 통째로 지워도 초록이다
# (변이 프로브 `SILENT`). 파일과 앵커를 **함께** 실제 테스트로 옮겼다.
sd_mask_test() {
  case "$1" in
    java)   printf '%s' 'java/keycloak-sdk-core/src/test/java/io/github/xzawed/keycloak/core/TokenSetTest.java' ;;
    kotlin) printf '%s' 'kotlin/src/test/kotlin/io/github/xzawed/keycloak/TokensTest.kt' ;;
    python) printf '%s' 'python/tests/unit/test_tokens.py' ;;
    node)   printf '%s' 'node/test/unit/tokens.test.ts' ;;
    go)     printf '%s' 'go/masking_test.go' ;;
    dotnet) printf '%s' 'dotnet/tests/Xzawed.Keycloak.Sdk.Tests/TokensTests.cs' ;;
    php)    printf '%s' 'php/tests/Unit/Token/TokenSetTest.php' ;;
    rust)   printf '%s' 'rust/src/tokens.rs' ;;
    ruby)   printf '%s' 'ruby/spec/unit/tokens_spec.rb' ;;
  esac
}
# 그 테스트가 **마스킹을 단언한다**는 앵커 — **아홉 전부 테스트 이름**이다.
# ⚠️ `***` 같은 리터럴을 앵커로 쓰면 안 된다: 그 파일의 **다른 테스트**가 그 문자열을 갖고 있으면
# 겨누던 카나리아가 사라져도 참이다(실측으로 겪었다). 문구가 아니라 **그 단언의 존재**를 겨눈다.
sd_mask_canary() {
  case "$1" in
    java)   printf '%s' 'toString_masksTokens' ;;
    go)     printf '%s' 'assertMasked' ;;
    rust)   printf '%s' 'fn debug_masks_tokens' ;;
    kotlin) printf '%s' 'TokenSet toString masks accessToken' ;;
    python) printf '%s' 'def test_repr_masks' ;;
    node)   printf '%s' 'toString/toJSON/inspect' ;;
    dotnet) printf '%s' 'ToString_masks_access_and_refresh' ;;
    php)    printf '%s' 'testToStringMasksTokens' ;;
    ruby)   printf '%s' 'masks tokens in inspect' ;;
  esac
}

_mask_seen=0
for L in $SD_LANGS; do
  _ms="$(sd_mask_src "$L")"
  _mt="$(sd_mask_test "$L")"
  _e=1; [ -f "$ROOT/$_ms" ] && _e=0
  assert_eq "ok" "$(ok_if "$_e" MISSING)" "[mask] $L 소스 파일이 없다($_ms)"
  _e=1; [ -f "$ROOT/$_mt" ] && _e=0
  assert_eq "ok" "$(ok_if "$_e" MISSING)" "[mask] $L 마스킹 테스트 파일이 없다($_mt)"
  [ -f "$ROOT/$_ms" ] && [ -f "$ROOT/$_mt" ] || continue
  _hp="$(sd_mask_hook "$L")"
  _h=1; grep -qF -- "$_hp" "$ROOT/$_ms" && _h=0
  assert_eq "ok" "$(ok_if "$_h" MISSING)" \
    "[mask] $L 비밀 보유 타입에 기본 문자열표현 마스킹 훅이 없다 — 기대: $_hp"
  _cp="$(sd_mask_canary "$L")"
  _c=1; grep -qF -- "$_cp" "$ROOT/$_mt" && _c=0
  assert_eq "ok" "$(ok_if "$_c" MISSING)" \
    "[mask] $L 마스킹을 단언하는 행위 테스트가 없다 — 기대: $_cp (훅만 남고 본문이 바뀌면 이것만이 잡는다)"
  _mask_seen=$((_mask_seen + 1))
done
assert_eq "9" "$_mask_seen" "[mask] 훑은 언어 수가 9가 아니다 — 추출 표가 낡았나?"

# ---------------------------------------------------------------------------
# 1d) 마스킹 축 (2) — 비밀 보유 타입은 `TokenSet` **하나가 아니다**
# ---------------------------------------------------------------------------
#
# 위 1c 는 `TokenSet` 만 겨눈다. 같은 바닥 계약을 지는 형제가 아홉 언어에 하나 더 있다 —
# PKCE `code_verifier` 를 쥔 인가요청 타입이다(`AuthorizationRequest`·`AuthorizationUrl`·
# `AuthorizationUrlRequest`). 검증자는 코드 교환의 소유 증명 비밀이라, 인가 코드를 훔친
# 공격자가 로그에서 이 값을 얻으면 흐름을 완성한다.
#
# 실측(2026-09-06, `scripts/probe.sh` 8회): 이 축을 세우기 전, 형제의 마스킹을 **원문 노출로
# 되돌리는** 변이를 여덟 언어에 넣었더니 **8/8 이 `SILENT`** 였다. 소스 경로가 이미 1c 목록 안인
# 다섯(kotlin·go·dotnet·rust·ruby)도 못 잡았다 — 1c 의 훅 앵커가 `TokenSet` 전용이거나
# generic(`def inspect`·`override fun toString()`)이라 **`TokenSet` 의 훅 하나가 그 grep 을
# 만족**시키기 때문이다. **「파일이 목록에 있으니 덮인다」는 이 축에서 거짓이다.**
#
# ⚠️ **앵커는 마스킹 자체를 포함해야 한다.** `override fun toString()` 같은 훅 이름은 실격이다 —
# 훅이 남은 채 본문이 원문을 찍어도 통과한다. 그래서 아래 앵커는 전부 `***` 이거나
# **그 필드에 대한 mask 호출**이다. 각 앵커는 위 프로브로 `SILENT → CAUGHT` 를 확인했다.
#
# ⚠️ **손으로 적힌 표다 — 파생으로 바꾸지 말 것(지금은).** 이 자가테스트는 저장소의 required
# 체크 `doc-facts` 안에서 `paths:` 필터 없이 돌고 룰셋 `PRIMARY` 는 `bypass_actors: []` 다.
# 오탐 하나가 **모든 PR** 을 막는다. 파생 열거의 되살릴 조건은 등록부가 소유한다.
sd_mask2_src() {
  case "$1" in
    java)   printf '%s' 'java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthorizationUrlRequest.java' ;;
    kotlin) printf '%s' 'kotlin/src/main/kotlin/io/github/xzawed/keycloak/tokens.kt' ;;
    python) printf '%s' 'python/src/keycloak_sdk/auth.py' ;;
    node)   printf '%s' 'node/src/auth.ts' ;;
    go)     printf '%s' 'go/tokens.go' ;;
    dotnet) printf '%s' 'dotnet/src/Xzawed.Keycloak.Sdk/Tokens.cs' ;;
    php)    printf '%s' 'php/src/Token/AuthorizationRequest.php' ;;
    rust)   printf '%s' 'rust/src/tokens.rs' ;;
    ruby)   printf '%s' 'ruby/lib/keycloak_sdk/tokens.rb' ;;
  esac
}
# 마스킹 **자체**를 담은 앵커. 훅 이름이 아니다(위 ⚠️).
# java 는 여기 없다 — 훅이 **없어서 안전**하기 때문이다(아래 별도 판정).
sd_mask2_hook() {
  case "$1" in
    kotlin) printf '%s' 'codeVerifier=***' ;;
    python) printf '%s' 'code_verifier={mask(self.code_verifier)!r}' ;;
    node)   printf '%s' 'codeVerifier: ${mask(this.codeVerifier)}' ;;
    go)     printf '%s' 'mask(a.CodeVerifier)' ;;
    dotnet) printf '%s' 'Masking.Mask(CodeVerifier)' ;;
    php)    printf '%s' 'Masking::mask($this->codeVerifier)' ;;
    rust)   printf '%s' '.field("code_verifier", &"***")' ;;
    ruby)   printf '%s' 'code_verifier=\"***\"' ;;
  esac
}
# 형제의 마스킹을 **실행해서** 단언하는 자리. 1c 의 테스트 파일과 다른 언어가 넷이다
# (kotlin·python·ruby 는 `TokenSet` 카나리아가 형제를 안 본다).
sd_mask2_test() {
  case "$1" in
    kotlin) printf '%s' 'kotlin/src/test/kotlin/io/github/xzawed/keycloak/TokensTest.kt' ;;
    python) printf '%s' 'python/tests/unit/test_auth.py' ;;
    node)   printf '%s' 'node/test/unit/masking.test.ts' ;;
    go)     printf '%s' 'go/masking_test.go' ;;
    dotnet) printf '%s' 'dotnet/tests/Xzawed.Keycloak.Sdk.Tests/MaskingTests.cs' ;;
    php)    printf '%s' 'php/tests/Unit/MaskingTest.php' ;;
    rust)   printf '%s' 'rust/src/tokens.rs' ;;
    ruby)   printf '%s' 'ruby/spec/unit/tokens_spec.rb' ;;
  esac
}
sd_mask2_canary() {
  case "$1" in
    kotlin) printf '%s' 'AuthorizationRequest toString masks codeVerifier' ;;
    python) printf '%s' 'test_authorization_url_repr_masks_verifier' ;;
    node)   printf '%s' 'not.toContain(req.codeVerifier)' ;;
    go)     printf '%s' 'AuthorizationRequest' ;;
    dotnet) printf '%s' 'AuthorizationRequest_ToString_masks_code_verifier' ;;
    php)    printf '%s' 'testJsonEncodeAndStringMaskAuthorizationRequest' ;;
    rust)   printf '%s' 'fn debug_masks_code_verifier' ;;
    ruby)   printf '%s' 'masks code_verifier in inspect' ;;
  esac
}

_mask2_seen=0
for L in $SD_LANGS; do
  _m2s="$(sd_mask2_src "$L")"
  _e=1; [ -f "$ROOT/$_m2s" ] && _e=0
  assert_eq "ok" "$(ok_if "$_e" MISSING)" "[mask2] $L 인가요청 타입 소스가 없다($_m2s)"
  [ -f "$ROOT/$_m2s" ] || continue
  if [ "$L" = java ]; then
    # ⚠️ java 만 **음성 앵커**다. `AuthorizationUrlRequest` 는 `record` 가 아닌 plain final
    # class 라 `Object.toString()` 이 필드를 애초에 안 찍는다 — 마스킹 훅이 **없어서 안전**하다.
    # 그래서 겨눌 것은 훅의 존재가 아니라 「record 로 바뀌지 않았다」다. record 가 되면
    # 컴파일러가 만든 toString 이 codeVerifier 를 원문으로 찍는다(.NET 이 positional record 라
    # ToString 을 손으로 덮어야 했던 것의 뒷면).
    _r=0; grep -qE 'record[[:space:]]+AuthorizationUrlRequest' "$ROOT/$_m2s" && _r=1
    assert_eq "ok" "$(ok_if "$_r" IS-RECORD)" \
      "[mask2] java AuthorizationUrlRequest 가 record 다 — 컴파일러 toString 이 codeVerifier 를 원문으로 찍는다. 마스킹 toString 을 손으로 덮거나 final class 로 되돌려라"
    _c=1; grep -qF -- 'final class AuthorizationUrlRequest' "$ROOT/$_m2s" && _c=0
    assert_eq "ok" "$(ok_if "$_c" MISSING)" \
      "[mask2] java AuthorizationUrlRequest 의 선언 형태가 바뀌었다 — 이 축의 안전 근거(필드를 안 찍는 기본 toString)가 무너졌는지 다시 판정하라"
    _mask2_seen=$((_mask2_seen + 1))
    continue
  fi
  _m2t="$(sd_mask2_test "$L")"
  _e=1; [ -f "$ROOT/$_m2t" ] && _e=0
  assert_eq "ok" "$(ok_if "$_e" MISSING)" "[mask2] $L 형제 마스킹 테스트 파일이 없다($_m2t)"
  [ -f "$ROOT/$_m2t" ] || continue
  _h2="$(sd_mask2_hook "$L")"
  _h=1; grep -qF -- "$_h2" "$ROOT/$_m2s" && _h=0
  assert_eq "ok" "$(ok_if "$_h" MISSING)" \
    "[mask2] $L 인가요청 타입이 PKCE 검증자를 가리지 않는다 — 기대: $_h2"
  _c2="$(sd_mask2_canary "$L")"
  _c=1; grep -qF -- "$_c2" "$ROOT/$_m2t" && _c=0
  assert_eq "ok" "$(ok_if "$_c" MISSING)" \
    "[mask2] $L 형제 마스킹을 단언하는 행위 테스트가 없다 — 기대: $_c2"
  _mask2_seen=$((_mask2_seen + 1))
done
assert_eq "9" "$_mask2_seen" "[mask2] 훑은 언어 수가 9가 아니다 — 추출 표가 낡았나?"

# ---------------------------------------------------------------------------
# 2) 문서 축 — 그 값을 말하는 소비자 문서
# ---------------------------------------------------------------------------
#
# ⚠️ **"파라미터명이 나오는 줄"이 아니라 "값을 말하는 줄"만 본다.** 전자로 잡으면
# `.claude/rules/java.md`의 "Nimbus 캐시 TTL(기본 5분)보다 작아야 한다" 같은 줄이 걸려
# 5 ≠ 30 으로 오탐이 난다. 그래서 파라미터명과 값-서술 신호를 **함께** 요구한다.
#
# ⚠️ 아홉 언어 README가 전부 자기 파라미터 이름을 적는다 — dotnet만 "30-second minimum
# interval"로 이름 없이 적고 있어서 탐지에서 빠졌고, 그래서 이름을 적도록 문서를 고쳤다
# (가드가 볼 수 없는 표현은 가드가 지켜주지 못한다).
SD_DOCS="$(cd "$ROOT" && git ls-files '*/README.md' '*/README.ko.md' 'README.md' 'README.ko.md' \
  'docs/guides/*.md' 'SECURITY.md' 2>/dev/null || true)"
_hasdocs=1; [ -n "$SD_DOCS" ] && _hasdocs=0
assert_eq "ok" "$(ok_if "$_hasdocs" EMPTY)" "소비자 문서 목록이 비었다 — git ls-files 패턴이 바뀌었나?"

sd_doc_axis() { # $1=라벨 $2=파라미터명 정규식 $3=기대값 $4=최소 히트 $5=값-서술 신호 정규식
  _hits=0
  for f in $SD_DOCS; do
    _lines="$(grep -inE "$2" "$ROOT/$f" 2>/dev/null | grep -E "$5" || true)"
    [ -n "$_lines" ] || continue
    # ⚠️ **자릿수 경계로 대조한다 — 부분문자열이면 안 된다.** `grep -F "30"`으로 했더니 문서가
    # `300s by default`라고 말해도 "30을 포함한다"는 이유로 통과했다(변이 MS3가 실측으로 잡았다).
    # 값 앞뒤가 숫자가 아니어야 그 값을 말한 것이다(`30.0`은 `.`이 비숫자라 여전히 매치된다).
    _bad="$(printf '%s\n' "$_lines" | grep -vE "(^|[^0-9])$3([^0-9]|\$)" || true)"
    assert_eq "" "$_bad" "[$1] $f 가 기본값을 코드값($3)과 다르게 말한다"
    _hits=$((_hits + $(printf '%s\n' "$_lines" | grep -c . || true)))
  done
  _enough=1; [ "$_hits" -ge "$4" ] && _enough=0
  assert_eq "ok" "$(ok_if "$_enough" "$_hits")" \
    "[$1] 기본값을 말하는 문서 줄을 $4건 미만 찾았다 — 탐지 패턴이 낡았나?"
}

# clock skew 문서 축 — 값을 말하는 자리는 **실측 8건**이다(2026-08-17 재측정):
# java·node·dotnet·rust·kotlin·go·php README와 `add-a-language-playbook.md`.
# ⚠️ 이 주석은 한때 `go`·`php`를 빠뜨리고 `ruby/README.ko.md`를 넣어 7건이라고 적고 있었다 —
# 하한(6)이 실측보다 낮아 아무도 눈치채지 못했다. ko 미러를 내리며(#217) 다시 세어 고쳤다.
# 하한을 6으로 두는 것은 여전히 옳다: 여유 2건이 문서 표현이 바뀔 여지를 준다.
# ⚠️ dotnet은 "30s by default, **down from the library's 5 minutes**"라 한 줄에 다른 숫자가
# 함께 있다 — 검사는 "코드값을 담고 있는가"라 통과한다(다른 숫자의 존재는 금지하지 않는다).
# ⚠️ **값-서술 신호를 파라미터별로 좁힌다.** JWKS는 "default"·"기본값" 같은 낱말 신호로 충분했지만
# clock skew는 그 낱말이 값 없는 산문에도 붙는다 — `add-a-language-playbook.md:37`의 "Fix defaults
# for timeouts, clock skew, and scopes"와 `:82`의 표 행이 실제로 걸려 **오탐 2건**이 났다(권고 5를
# 기각시킨 것과 같은 부류: 문구가 아니라 문맥이 값-서술 여부를 정한다). 그래서 clock skew는
# **시간량(`30s`·`30초`)이나 설정표의 순수 숫자 셀**이 있는 줄만 대상으로 삼는다.
sd_doc_axis "clock skew" 'clock.?skew' "$sd_skew_expect" 6 \
  '[0-9]+ ?s\b|[0-9]+ ?(초|seconds)|\| *`?[0-9][0-9.]*`? *\|'

sd_hits=0
for f in $SD_DOCS; do
  # ⚠️ **설정표 행(`^N:|`)을 신호에 반드시 포함할 것.** 이 가드를 만든 바로 그 결함
  # (`ruby/README.ko.md:72`의 `10.0`)은 한글 표 행이라 "default"도 "기본값"도 없다 —
  # 산문 신호만 요구했더니 **변이검증에서 그 줄이 그대로 통과했다**(MC2: 29 passed, 0 failed).
  # 가드가 겨눈 실물을 변이로 재현해 보지 않았으면 공허한 채로 커밋될 뻔했다.
  _lines="$(grep -inE 'jwks[_ ]?min[_ ]?refetch|RefreshIntervalSeconds' "$ROOT/$f" 2>/dev/null \
    | grep -iE 'default|기본값|minimum interval|throttled|cooldown|^[0-9]+:\|' || true)"
  [ -n "$_lines" ] || continue
  # ⚠️ **자릿수 경계로 대조한다**(위 `sd_doc_axis`와 같은 이유). 고정문자열 `grep -F "30"`이면
  # 문서가 `300s by default`라 해도 "30을 포함한다"는 이유로 통과한다 — clock skew 변이 MS3가
  # 그 구멍을 실측으로 드러냈고, 이 자리도 같은 구멍이었다.
  _bad="$(printf '%s\n' "$_lines" | grep -vE "(^|[^0-9])$sd_expect([^0-9]|\$)" || true)"
  assert_eq "" "$_bad" "$f 가 JWKS 최소 재조회 기본값을 코드값($sd_expect)과 다르게 말한다"
  sd_hits=$((sd_hits + $(printf '%s\n' "$_lines" | grep -c . || true)))
done

# 대조군 — 문서 축이 실제로 무언가를 봤는가. **아홉 언어 README가 각 1건씩, 실측 9건**이다.
# 이 하한이 없으면 탐지 정규식이 깨졌을 때 "볼 것이 없어서" 초록이 된다.
# ⚠️ **2026-08-17: 10 → 9.** `ruby/README.ko.md`가 이 축에 1건을 기여하고 있었는데 그 파일을
# 내렸다(#217 — 9개 언어 중 2개만 있던 ko 미러가 명문 규칙 밖이었다. `python/README.ko.md`는
# 이 축에 0건이라 무관하다). **하한을 내린 것은 탐지 약화가 아니라 대상 집합이 줄어든 것**이고,
# 지금은 "아홉 언어 = 아홉 건"이라 하한과 의미가 1:1로 붙어 오히려 읽기 쉬워졌다.
_enough=1; [ "$sd_hits" -ge 9 ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$sd_hits")" \
  "기본값을 말하는 문서 줄을 10건 미만 찾았다 — 탐지 패턴이 낡았나?"

# ---------------------------------------------------------------------------
# 2b) **소스 주석** 축 — 공개 API 의 doc 주석도 기본값을 말한다
# ---------------------------------------------------------------------------
#
# ⚠️ **2절(문서 축)은 README·docs 만 본다**(`SD_DOCS` = `git ls-files '*/README.md' 'docs/guides/*'…`).
# 그래서 **소스의 doc 주석이 값을 틀리게 말해도 아무 가드가 못 봤다** — 실측으로 3건이 살아 있었다:
#
#     python/src/keycloak_sdk/config.py:23   "(초, 기본 60)"   실제 30.0 (두 줄 아래)
#     rust/src/config.rs:18                  "(초, 기본 60)"   실제 30
#     rust/src/config.rs:81                  "(… 기본 60)"     실제 30
#
# rust 의 둘은 **공개 API의 rustdoc** 이라 docs.rs 에 그대로 렌더된다 — 소비자가 읽는 자리다.
# 값의 SSOT 는 코드이므로, 주석이 값을 말하면 그 말이 코드와 같은지 기계로 대조한다.
#
# ⚠️ **파일 목록을 손으로 열거하지 않는다.** config 파일만 훑도록 좁히면 새 자리가 조용히
# 통과한다(원장 `guard-detection-surface-hand-narrowed` 와 같은 부류). 아홉 언어 소스 전체를
# 훑되 **테스트를 뺀다** — 이 축이 겨누는 것은 *소비자가 읽는* 주석이고, 테스트 주석은 이웃한
# 다른 값을 말한다(실측 오탐 1건: `JwtValidatorTest.kt:515` 의 "Nimbus 캐시 TTL(기본 5분)" —
# 재조회 간격이 아니라 **상한** 이야기다).
#
# ⚠️ **"기본/default 뒤 6자 이내에 숫자"만 값 주장으로 본다.** 이 조건이 없으면 값을 말하지
# 않는 산문까지 대상이 되어(`ruby/config.rb:41` "기본값은 위 상수." · `php/KeycloakConfig.php:20`)
# "30을 안 담았다"는 이유로 전부 거짓 실패한다. 상수를 **참조**하는 주석은 드리프트할 수 없으니
# 검사 대상이 아닌 것이 옳다.
SD_SRC="$(cd "$ROOT" && git ls-files 'java/*.java' 'python/*.py' 'node/src/*.ts' 'go/*.go' \
  'dotnet/*.cs' 'php/*.php' 'rust/src/*.rs' 'ruby/*.rb' 'kotlin/*.kt' 2>/dev/null \
  | grep -viE '(^|/)(tests?|spec)/|[Tt]est[s]?\.(java|kt|ts|go|cs|php|rb|py|rs)$|_test\.go$|test_.*\.py$|_spec\.rb$|\.test\.ts$' || true)"
_hassrc=1; [ -n "$SD_SRC" ] && _hassrc=0
assert_eq "ok" "$(ok_if "$_hassrc" EMPTY)" "소스 목록이 비었다 — git ls-files 패턴이 바뀌었나?"

sd_src_hits=0
for f in $SD_SRC; do
  _lines="$(grep -inE 'jwks[_ ]?min[_ ]?refetch|재조회|refetch' "$ROOT/$f" 2>/dev/null \
    | grep -E '(//|#|\*|///)' \
    | grep -iE '(기본|default)[^0-9]{0,6}[0-9]' || true)"
  [ -n "$_lines" ] || continue
  # 자릿수 경계로 대조(2절과 같은 이유 — `grep -F 30`이면 `300`도 통과한다).
  _bad="$(printf '%s\n' "$_lines" | grep -vE "(^|[^0-9])$sd_expect([^0-9]|\$)" || true)"
  assert_eq "" "$_bad" "$f 의 주석이 JWKS 최소 재조회 기본값을 코드값($sd_expect)과 다르게 말한다"
  sd_src_hits=$((sd_src_hits + $(printf '%s\n' "$_lines" | grep -c . || true)))
done

# 대조군 — 이 축이 실제로 무언가를 봤는가. **실측 9건**(2026-09-04, 위 3건을 고친 뒤):
#   go/config.go:42 · java JwtValidator.java:38 · java KeycloakConfig.java:40 ·
#   kotlin config.kt:22 · node config.ts:26 · node jwt.ts:10 ·
#   python config.py:23 · rust config.rs:18 · rust config.rs:81
# ⚠️ 9는 **언어당 1건이 아니다**(6개 언어에 흩어져 있고 dotnet·php·ruby 는 0건) — 2절의 9와
# 우연히 같을 뿐이니 같은 뜻으로 읽지 말 것. 하한을 8로 두어 표현이 한 줄 바뀔 여지를 남긴다.
_enough=1; [ "$sd_src_hits" -ge 8 ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$sd_src_hits")" \
  "기본값을 말하는 소스 주석을 8건 미만 찾았다 — 탐지 패턴이 낡았나?"

# ---------------------------------------------------------------------------
# 3) 2차 정의 자리 금지 — 같은 값을 두 번 적지 않는다
# ---------------------------------------------------------------------------
#
# ⚠️ 1절은 "config 기본값 아홉이 서로 같은가"만 본다. 그런데 이 값이 **한 언어 안에서 두 번**
# 적히면 그 둘이 갈라지는 것을 1절이 못 본다 — 실제로 그랬다(go 30/60 · php 30/60 · ruby 30.0/10.0).
# 그래서 2차 자리가 상수를 **참조**하는지(리터럴이 아닌지) 문자로 확인한다.
sd_no_literal() { # $1=라벨 $2=파일 $3=파라미터가 등장하는 줄의 앵커
  _l="$(grep -m1 -F "$3" "$ROOT/$2" || true)"
  _found=1; [ -n "$_l" ] && _found=0
  assert_eq "ok" "$(ok_if "$_found" MISSING)" "[$1] 2차 정의 자리를 찾지 못했다($3) — 표기가 바뀌었나?"
  [ -n "$_l" ] || return 0
  # ⚠️ **줄 전체가 아니라 앵커 바로 뒤의 값 자리만 본다.** 처음에는 "줄에 숫자가 있으면 2차 정의"로
  # 했는데, ruby `JwtValidator`의 같은 줄에 있는 `algorithms: ["RS256"]`의 **256이 걸려 오탐**이 났다.
  # 값 자리에 숫자가 오면 리터럴, 식별자가 오면 상수 참조다.
  _rest="${_l#*"$3"}"
  case "$_rest" in
    [0-9]* | ' '[0-9]* | '"'[0-9]* )
      assert_eq "" "$_l" "[$1] 2차 정의 자리에 숫자 리터럴이 있다 — config 상수를 참조할 것(정의 자리는 언어당 하나)" ;;
    *) assert_eq "ok" "ok" ;;
  esac
}
# ⚠️ go 앵커의 **뒤 공백이 하중을 받는다** — `opts.minRefetch =`(공백 없음)로 잡으면 바로 위의
# `if opts.minRefetch == 0 {`이 먼저 걸려 그 `0`을 2차 리터럴로 오인한다(실측 오탐).
sd_no_literal go   go/jwt.go                        'opts.minRefetch = '
sd_no_literal php  php/src/Jwks/JwksStore.php       'private readonly int $minRefetchIntervalSeconds ='
sd_no_literal ruby ruby/lib/keycloak_sdk/jwks_store.rb 'def initialize(jwks_url:, http:, min_refetch:'
# clock skew도 ruby에 2차 자리가 있었다 — `JwtValidator`도 public 클래스라 소비자가 직접 생성할 수
# 있고, 두 자리가 갈리면 그 경로에서만 만료된 토큰이 더 오래 통과한다. 값은 아직 갈리지 않았지만
# (둘 다 30) JWKS가 10.0/30.0으로 갈린 것과 **똑같은 모양**이라 같은 방식으로 닫았다.
sd_no_literal ruby-skew ruby/lib/keycloak_sdk/jwt_validator.rb 'algorithms: ["RS256"], clock_skew:'

# ---------------------------------------------------------------------------
# 4) 소유자 문서 축 — 이 값을 **선언하는** 두 문서
# ---------------------------------------------------------------------------
#
# ⚠️ 위 문서 축(`SD_DOCS`)은 **소비자 문서만** 겨눈다. 그건 옳은 스코프였지만 구멍이 하나
# 있었다: 이 불변식을 선언하는 `CLAUDE.md` 와 `.claude/rules/security.md` 는 그 목록에 없다.
# 그래서 아홉 소비자 사본은 검사받고, **정작 규칙의 소유자 둘은 아무도 안 봤다.**
# (CLAUDE.md 는 그 줄에서 이 파일을 자기 가드로 지목까지 하고 있었다.)
#
# ⚠️ 파일 상단이 제외한 것은 `docs/governance/` 같은 **기록** 문서다. 이 둘은 기록이 아니라
# 상주 규칙이고, 값이 어긋나면 그건 이력이 아니라 드리프트다. 그래서 여기서 정책값과 대조한다.
sd_owner_axis() { # $1=파일 $2=값을 말하는 줄의 정규식
  _f="$ROOT/$1"
  _exists=1; [ -f "$_f" ] && _exists=0
  assert_eq "ok" "$(ok_if "$_exists" MISSING)" "소유자 문서 $1 이 없다 — 경로가 바뀌었나?"
  [ -f "$_f" ] || return 0
  # 그 값을 말하는 줄만 뽑아, 정책값을 **자릿수 경계로** 담고 있는지 본다(`300` 이 `30` 으로
  # 읽히지 않도록 — 위 문서 축이 같은 이유로 겪은 부류다).
  _lines="$(grep -E "$2" "$_f" || true)"
  _n="$(printf '%s\n' "$_lines" | grep -c . || true)"
  assert_ok test "$_n" -ge 1
  _bad="$(printf '%s\n' "$_lines" | grep -vE "(^|[^0-9])$SD_POLICY([^0-9]|$)" || true)"
  assert_eq "" "$_bad" "$1 이 정책값 $SD_POLICY 을 말하지 않는 줄로 이 불변식을 서술한다"
}
sd_owner_axis "CLAUDE.md" 'JWKS 재조회 최소 간격'
sd_owner_axis ".claude/rules/security.md" 'JWKS minimum refetch interval defaults'
sd_owner_axis ".claude/rules/security.md" 'is the same invariant and is likewise'

# ---------------------------------------------------------------------------
# 음성 대조군 — 이 파일이 **라이브 상태만** 단언하고 있지 않은가
# ---------------------------------------------------------------------------
#
# ⚠️ 위 축들은 전부 「지금 트리가 일치한다」를 본다. 그 형태의 검사는 **추출기가 no-op 이어도**
# 통과한다 — `sd_default() { echo 30; }` 로 바꿔도 아홉이 전부 30 이라 초록이다. 그러면 이 파일은
# 있으나 마나가 되고, 그 사실을 아무도 모른다(`seven-selftests-have-no-negative-control`).
#
# 그래서 값 하나만 바꾼 TMP 트리를 만들어 **추출기가 그 변화를 실제로 본다**는 것을 확인한다.
# ⚠️ 트리 전체를 복사하지 않는다 — 추출기가 읽는 **그 파일 하나**만 같은 상대경로로 놓는다.
# 트리 복사는 CI 에서 실패할 자리를 늘리고, 이 파일은 required 체크 안에서 돈다.
#
# ⚠️ 라이브 루트가 여전히 기대값을 낸다는 **양성 대조**를 함께 둔다 — 없으면 「추출기가 늘 빈
# 문자열을 낸다」와 구분되지 않는다.
sd_negative_control() { # $1=라벨 $2=추출함수 $3=언어 $4=상대경로 $5=sed표현식 $6=기대(바뀐값)
  _nc_tmp="$(mktemp -d)"
  mkdir -p "$_nc_tmp/$(dirname "$4")"
  sed "$5" "$ROOT/$4" > "$_nc_tmp/$4"
  _nc_got="$(SD_ROOT="$_nc_tmp" ROOT="$_nc_tmp" "$2" "$3" || true)"
  rm -rf "$_nc_tmp"
  assert_eq "$6" "$(sd_norm "$_nc_got")" \
    "[음성대조] $1: 값을 바꾼 트리에서도 $6 이 안 나온다 — 추출기가 파일을 안 읽거나(no-op) 표기가 바뀌었다"
}

# JWKS 재조회 간격: java 의 30 → 11 로 바꾼 사본에서 추출기가 11 을 내야 한다.
sd_negative_control "JWKS 재조회" sd_default java \
  'java/keycloak-sdk-core/src/main/java/io/github/xzawed/keycloak/core/KeycloakConfig.java' \
  's/jwksMinRefetch = Duration.ofSeconds(30)/jwksMinRefetch = Duration.ofSeconds(11)/' 11
# clock skew: python 의 30.0 → 12.0.
sd_negative_control "clock skew" sd_skew python \
  'python/src/keycloak_sdk/config.py' \
  's/clock_skew: float = 30.0/clock_skew: float = 12.0/' 12

# 양성 대조 — 라이브 루트는 여전히 못박힌 값을 낸다(위가 「늘 다른 값을 낸다」가 아님을 보인다).
assert_eq "$sd_expect" "$(sd_norm "$(sd_default java)")" "[음성대조·양성] 라이브 java JWKS 값이 바뀌었다"
assert_eq "$sd_skew_expect" "$(sd_norm "$(sd_skew python)")" "[음성대조·양성] 라이브 python skew 값이 바뀌었다"

# ---------------------------------------------------------------------------
# 1c) 토큰응답 `access_token` **타입 검증** — 아홉 언어 축
# ---------------------------------------------------------------------------
#
# 불변식: **`access_token` 이 비어 있지 않은 JSON 문자열이 아니면 TokenSet 을 만들지 않는다.**
# 아니면 소비자가 쓸 수 없는 값을 Bearer 로 실어 보내고 매번 401 을 받는다 — 패닉도 재시도도
# 아니라 조용한 반복 실패다(rust 는 캐시 때문에 만료까지 지속된다).
#
# ⚠️ **존재 검사는 타입 검사가 아니다.** 2026-09-12 전수 측정에서 **다섯**이 이 부류였다:
# rust(`unwrap_or_default` → 빈 문자열) · python(무검사) · ruby(무검사) · php(`toStr` 강제변환)
# · dotnet(**Duende 가 강제변환**해 `IsNullOrEmpty` 를 통과 — 그래서 원본 JSON 의 `ValueKind`
# 를 본다). java·kotlin·node·go 는 이미 거부하고 있었다.
#
# ⚠️ **언어마다 「거부하는 기제」가 다르므로 값이 아니라 그 기제를 겨눈다.** JVM 둘은 우리
# 코드가 아니라 Nimbus `TokenResponse.parse` 가 타입을 강제한다(실험 확인: 숫자·null·객체·
# 누락·빈문자열 전부 `ParseException`). 그 호출을 다른 것으로 바꾸면 보호가 사라지므로 **그
# 호출의 존재**가 이 언어들의 앵커다.
#
# ⚠️ `expires_in` 의 문자열 허용은 이 축이 겨누지 않는다 — php·ruby 가 테스트로 고정해 둔
# 의도된 관용이다.
# ⚠️ **앵커가 두 종류인 것은 의도다.**
#   · 이번에 고친 다섯은 **행동을 단언하는 테스트**를 앵커로 쓴다. 검증을 지우면 그 언어의
#     테스트가 먼저 빨개지므로 축은 「그 테스트가 사라지지 않았는가」만 지키면 된다.
#     소스 철자를 겨누면 **동작이 같은 리팩터에도 빨개진다**(실측: rust 의
#     `serde_json::Value::as_str` → `|v| v.as_str()` 로 바꿨을 뿐인데 걸렸다).
#   · 이미 옳던 넷은 그런 테스트가 **없다**. 그래서 그쪽은 집행 기제 자체를 겨눈다 —
#     JVM 둘은 우리 코드가 아니라 Nimbus `TokenResponse.parse` 가 타입을 강제하므로
#     **그 호출의 존재**가 앵커다. (넷에 테스트를 붙이면 그때 이쪽으로 옮긴다.)
sd_token_type_guard() { # $1=언어 → 불변식을 지키는 앵커의 히트 수(없으면 0/빈 문자열)
    case "$1" in
    rust)   grep -c 'non_string_access_token_is_rejected' "$ROOT/rust/src/token_provider.rs" ;;
    python) grep -c 'test_non_string_access_token_is_rejected' \
              "$ROOT/python/tests/unit/test_tokens.py" ;;
    ruby)   grep -c 'rejects a non-string access_token' "$ROOT/ruby/spec/unit/tokens_spec.rb" ;;
    php)    grep -c 'testNonStringAccessTokenIsRejected' \
              "$ROOT/php/tests/Unit/Token/TokenSetTest.php" ;;
    dotnet) grep -c 'ClientCredentialsToken_rejects_non_string_access_token' \
              "$ROOT/dotnet/tests/Xzawed.Keycloak.Sdk.Tests/AuthClientTests.cs" ;;
    node)   grep -c "typeof at !== 'string'" "$ROOT/node/src/tokens.ts" ;;
    go)     grep -c 'jwt.AccessToken == ""' "$ROOT/go/admin.go" ;;
    java)   grep -c 'TokenResponse.parse(' \
              "$ROOT/java/keycloak-sdk-auth/src/main/java/io/github/xzawed/keycloak/auth/AuthClient.java" ;;
    kotlin) grep -c 'TokenResponse.parse(' "$ROOT/kotlin/src/main/kotlin/io/github/xzawed/keycloak/auth.kt" ;;
  esac
}

SD_TOKEN_TYPE_LANGS='rust python ruby php dotnet node go java kotlin'
sd_tt_seen=0
for L in $SD_TOKEN_TYPE_LANGS; do
  _hits="$(sd_token_type_guard "$L" 2>/dev/null || printf '0')"
  [ -n "$_hits" ] || _hits=0
  assert_eq "ok" "$(ok_if "$([ "$_hits" -ge 1 ] && printf 0 || printf 1)" MISSING)" \
    "[토큰 타입검증] $L 에서 access_token 타입 검증 기제가 사라졌다 — 쓸 수 없는 토큰이 성공으로 나간다"
  [ "$_hits" -ge 1 ] && sd_tt_seen=$((sd_tt_seen + 1))
done
# 공허 하한 — 목록이 비거나 case 가 낡으면 어서션이 0건 실행되고 조용히 통과한다.
assert_eq "9" "$sd_tt_seen" "[토큰 타입검증] 확인한 언어 수가 9가 아니다 — 추출 표가 낡았나?"

assert_report
