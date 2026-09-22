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

# ---------------------------------------------------------------------------
# 빈 키셋 거부 — 자체 JWKS 스토어를 가진 넷
# ---------------------------------------------------------------------------
# ⚠️ go 의 #380 픽스는 **두 절반**이었다 — 상태코드 거부와 `len(ks.Keys) == 0` 거부. 자매 SDK
# 로는 **앞 절반만** 복제됐고, 뒤 절반이 없는 rust·ruby·php 는 200 + `{"keys":[]}` 하나로 좋은
# 캐시가 덮였다(실행 가능한 프로브로 재현, 2026-09-22). 더 나쁜 것은 go 자신도 **뒤 절반에
# 테스트가 없었다**는 점이다 — 그 줄을 지워도 아무도 울지 않았다(변이 실측: 지우면 새 테스트만
# 운다). 그래서 이 축은 **거부 지점**과 **그것을 잡는 테스트**를 함께 본다. 한쪽만 보면 코드를
# 지우고 테스트만 남기거나 그 반대가 통과한다.
#
# ⚠️ 여기 없는 다섯의 이유: python 은 joserfc 가 빈 키셋에서 `MissingKeyError` 를 던져 대입
# 전에 막는다(실측). node·java·kotlin·dotnet 은 하위 라이브러리가 fetch·캐시를 소유해 이 자리가
# 우리 코드에 없다 — 그쪽은 별도 항목이고, 목록에 넣으면 추출 실패가 곧 빨강이 된다.
sd_empty_reject() {
  case "$1" in
    go) printf '%s\n' "go/jwt.go" ;;
    rust) printf '%s\n' "rust/src/jwks.rs" ;;
    ruby) printf '%s\n' "ruby/lib/keycloak_sdk/jwks_store.rb" ;;
    php) printf '%s\n' "php/src/Jwks/JwksStore.php" ;;
  esac
}
sd_empty_test() {
  case "$1" in
    go) printf '%s\t%s\n' "go/jwt_test.go" "TestValidateJWKSEmpty200DoesNotPoisonCache" ;;
    rust) printf '%s\t%s\n' "rust/src/jwks.rs" "empty_keyset_200_does_not_clobber_a_good_cache" ;;
    ruby) printf '%s\t%s\n' "ruby/spec/unit/jwks_store_spec.rb" "좋은 캐시를 덮지 않는다" ;;
    php) printf '%s\t%s\n' "php/tests/Unit/Jwks/JwksStoreTest.php" "testEmptyKeySetDoesNotClobberAGoodCache" ;;
  esac
}

SD_EMPTY_LANGS='go rust ruby php'
sd_subset_of_langs "SD_EMPTY_LANGS" "$SD_EMPTY_LANGS"
sd_empty_seen=0
for L in $SD_EMPTY_LANGS; do
  _src="$(sd_empty_reject "$L")"
  _n="$(grep -c 'contains no keys' "$ROOT/$_src" 2>/dev/null || printf '0')"
  assert_eq "ok" "$(ok_if "$([ "$_n" -ge 1 ] && printf 0 || printf 1)" MISSING)" \
    "[빈 키셋] $L 이 빈 JWKS 를 거부하지 않는다 — $_src 에 'contains no keys' 가 없다(go #380 의 나머지 절반)"
  _t="$(sd_empty_test "$L")"
  _tf="${_t%%	*}"; _tn="${_t##*	}"
  _tn_hits="$(grep -c -- "$_tn" "$ROOT/$_tf" 2>/dev/null || printf '0')"
  assert_eq "ok" "$(ok_if "$([ "$_tn_hits" -ge 1 ] && printf 0 || printf 1)" MISSING)" \
    "[빈 키셋] $L 의 회귀 테스트가 사라졌다 — $_tf 에 '$_tn' 이 없다(코드만 남고 증명이 없다)"
  [ "$_n" -ge 1 ] && [ "$_tn_hits" -ge 1 ] && sd_empty_seen=$((sd_empty_seen + 1))
done
# 대조군 — 목록이 비면 어서션이 0건 실행되고 조용히 통과한다.
assert_eq "4" "$sd_empty_seen" "[빈 키셋] 거부+테스트를 함께 가진 언어 수가 4가 아니다 — 추출 표가 낡았나?"

# ⚠️ **둘째 정의 자리는 이제 손 표가 아니라 파생이 본다 — 아래 3절.** 여기 있던
# `sd_skew_secondary`(dotnet·python 두 줄짜리 표)는 **중복이 되어 지웠다**(2026-09-16):
# 3절의 파생이 같은 두 자리를 값으로 잡는다(실측 — 손 표를 죽이고 python 을 60 으로 바꿔도
# 파생이 `CAUGHT`). 반대로 **손 표만 죽이면 아무도 울지 않았다**(`SILENT`) — 그것이 중복 게이트의
# 정의이고, 중복은 변이검증을 공허하게 만든다(이 저장소가 node 콜드캐시에서 이미 치른 값).
#
# ⚠️ **그 표가 갖고 있던 지식은 여기 남긴다 — dotnet 은 1절이 읽는 쪽이 소비자 값이 아니다.**
#   dotnet  1절은 `JwtValidator.cs` 를 읽지만, 파사드가 `ClockSkewSeconds = cfg.ClockSkewSeconds`
#           로 넘기므로(`KeycloakClient.cs`) **소비자가 받는 값은 `KeycloakConfig.cs` 쪽**이다.
#   python  `config.py`(1절) + `_internal/jwt.py` 의 파라미터 기본값.
# 실측 2026-08-29: `KeycloakConfig.cs` 를 30 → 300 으로 바꿔도 당시 가드는 **103/0 으로 통과**했다
# (dotnet 단위테스트가 대신 잡았다). 값이 갈리는 자리를 가드가 안 보면 그 초록은 공허하다.
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

sd_doc_axis() { # $1=라벨 $2=파라미터명re $3=기대값 $4=최소히트 $5=값-서술 신호re $6=코퍼스 $7=중간필터re
  # $6 생략 시 `$SD_DOCS`(문서 코퍼스) · $7 생략 시 `.`(모든 줄 통과 = 필터 없음).
  # ⚠️ **소스 주석 축이 이 함수의 복사본이었다** — 다른 점은 코퍼스(`SD_SRC`)와 주석 줄만 남기는
  # 중간 필터(`(//|#|\*|///)`) 둘뿐이었다. 문서 축에서 복제가 곧 구멍이었던 것과 같은 모양이라
  # (#495 실측) 인자 둘로 접었다. 이제 값 비교와 히트 하한이 **한 벌**이고, 대조군도 한 벌이다.
  _hits=0
  _ax_corpus="${6:-$SD_DOCS}"
  _ax_mid="${7:-.}"
  for f in $_ax_corpus; do
    _lines="$(grep -inE "$2" "$ROOT/$f" 2>/dev/null | grep -E "$_ax_mid" | grep -iE "$5" || true)"
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
    "[$1] 기본값을 말하는 줄을 $4건 미만 찾았다 — 탐지 패턴이 낡았나?"
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

# JWKS 재조회 문서 축 — **아홉 언어 README 가 각 1건씩, 실측 9건**이다.
# ⚠️ **이 블록은 한때 `sd_doc_axis` 를 복사한 인라인 루프였다.** 같은 비교가 두 벌이었고, 음성
# 대조군이 세 번째 벌이 되면서 **셋 중 하나를 무력화해도 아무도 못 봤다**(실측 2026-09-13:
# 인라인의 `_bad=""` → SILENT). 복제를 지우는 것이 곧 수정이다 — 축은 한 벌만 존재하고,
# 아래 음성 대조군이 **그 한 벌을** 태운다.
# ⚠️ **설정표 행(`^N:|`)을 신호에 반드시 포함할 것.** 이 가드가 겨눈 실물(`ruby/README.ko.md:72`
# 의 `10.0`)은 한글 표 행이라 "default"도 "기본값"도 없다 — 산문 신호만 요구했더니 변이검증에서
# 그 줄이 그대로 통과했다(MC2: 29 passed, 0 failed).
# ⚠️ **하한 9의 뜻**: 2026-08-17 에 10 → 9(ko 미러 `ruby/README.ko.md` 를 #217 로 내렸다 —
# 대상 집합이 준 것이지 탐지가 약해진 것이 아니다). 지금은 "아홉 언어 = 아홉 건"이라 1:1 이다.
# ⚠️ 인라인일 때 실패 문구가 `9` 가 아니라 **`10건 미만`** 이라고 말하고 있었다(하한을 내리며
# 상수만 고치고 문구를 안 고쳤다). 축은 문구를 `$4` 에서 만들므로 그 부류가 사라진다.
sd_doc_axis "JWKS 재조회" 'jwks[_ ]?min[_ ]?refetch|RefreshIntervalSeconds' "$sd_expect" 9 \
  'default|기본값|minimum interval|throttled|cooldown|^[0-9]+:\|'

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
# ⚠️ **글롭을 손으로 적지 않는다.** 예전에는 아홉 개 경로 글롭이었고, 그중 **하나를 지워도
# 조용했다**(실측: kotlin 글롭 제거 → `scripts/probe.sh` **SILENT**). 총 히트 하한(아래 8)은
# 아홉이 기여하는 상태에서 하나가 빠지는 것을 못 본다 — 셋을 지워야 비로소 걸렸다.
# 그래서 스캔 집합을 **위 언어 집합에서 파생**하고 **언어별 기여**를 따로 단언한다.
#
# ⚠️ 이 파생은 `node/src`·`rust/src` 로 좁혀 두었던 비대칭도 없앤다 — 그 둘만 `src/` 밖의
# 소스를 못 봤다. 확장으로 더해지는 것은 examples·vitest 설정 **넷**이고, 실측으로 그 넷은
# 이 축의 대상 패턴(`refetch`·`재조회`)을 **한 번도 담지 않는다**(required 체크라 확인했다).
# ⚠️ 정규식에 역슬래시를 쓰지 않는다 — `[.]` 로 적는다(세 겹 이스케이프에서 먹힌 이력).
SD_SRC="$(cd "$ROOT" && git ls-files $(for _l in $SD_LANGS; do printf '%s/ ' "$_l"; done) 2>/dev/null \
  | grep -E '[.](java|py|ts|go|cs|php|rs|rb|kt)$' \
  | grep -viE '(^|/)(tests?|spec)/|[Tt]est[s]?[.](java|kt|ts|go|cs|php|rb|py|rs)$|_test[.]go$|test_.*[.]py$|_spec[.]rb$|[.]test[.]ts$' || true)"
# ⚠️ **이 단언에는 대조군을 세울 수 없다 — 격리 입력이 존재하지 않는다.** 실측(2026-09-14):
# 코퍼스를 비우면 **셋이 동시에** 운다(이 단언 · 언어별 기여 · 히트 하한). 즉 이 단언이 우는
# 입력은 전부 다른 둘도 우는 입력이라, 「이 단언이 no-op 이 아니다」를 보일 방법이 없다.
# 실제로 이 줄을 `_hassrc=0` 으로 죽여도 **SILENT** 다 — 그러나 그것은 구멍이 아니라 **중복**이다
# (이 단언이 막아야 할 상태는 다른 둘이 이미 막는다). **남겨 두는 이유는 메시지다** — 파생이
# 깨졌을 때 「하한 미달」보다 「목록이 비었다」가 원인을 곧장 가리킨다.
# ⚠️ **「변이가 SILENT」와 「그 단언이 불필요」를 같은 말로 쓰지 말 것.** 판정은 변이가 아니라
# **그 단언이 막는 상태를 만들어** 무엇이 우는지로 한다.
_hassrc=1; [ -n "$SD_SRC" ] && _hassrc=0
assert_eq "ok" "$(ok_if "$_hassrc" EMPTY)" "소스 목록이 비었다 — 언어 집합 파생이나 확장자 필터가 깨졌나?"

# ⚠️ **언어별 기여** — 총 히트 하한과 **다른 양**을 센다(스캔된 파일 vs 값을 말하는 주석 줄).
# 이것이 위 구멍을 닫는 단언이고, 하한을 올리는 것으로는 닫히지 않는다(정당한 삭제에 오탐이 난다).
# ⚠️ **함수로 뺀 이유는 대조군 때문이다.** 최상위 인라인이면 「이 검사가 no-op 이 아니다」를
# 보일 방법이 없다 — 실측(2026-09-14): 루프를 `:` 로 죽여도 **SILENT** 였다.
sd_lang_contribution_axis() { # $1=라벨 $2=파일목록
  _lc_miss=''
  for L in $SD_LANGS; do
    printf '%s\n' "$2" | grep -q "^$L/" || _lc_miss="$_lc_miss $L"
  done
  assert_eq "" "$_lc_miss" \
    "[$1] 스캔 집합에 이 언어의 소스가 하나도 없다 —$_lc_miss (그 언어는 이 축에서 조용히 빠진다)"
}
sd_lang_contribution_axis "소스 주석 축" "$SD_SRC"

# ⚠️ **음성 대조군 — 이 검사가 실제로 언어를 세는가.** 한 언어의 파일을 전부 뺀 목록을 주면
# 반드시 울어야 한다. 축 **자신**을 태운다(대조군 안에 세기를 다시 구현하지 않는다 — #495 가
# 그렇게 해서 같은 변이를 놓쳤다).
sd_lang_contribution_control() { # $1=빠뜨릴 언어
  _a_save
  _lcc_list="$(printf '%s\n' "$SD_SRC" | grep -v "^$1/" || true)"
  sd_lang_contribution_axis "음성대조-내부" "$_lcc_list" >/dev/null 2>&1 || true
  _lcc_grew=1; [ "$_A_FAIL" -gt "$_A_SAVE_F" ] && _lcc_grew=0
  _a_restore
  assert_eq "ok" "$(ok_if "$_lcc_grew" DID-NOT-FAIL)" \
    "[음성대조·언어기여] $1 의 파일을 전부 뺀 목록에서도 통과했다 — 언어별 기여 검사가 no-op 이다"
}
# ⚠️ **양성 대조** — 라이브 목록에서는 조용해야 한다(「늘 운다」와 구분한다).
sd_lang_contribution_positive() {
  _a_save
  sd_lang_contribution_axis "양성대조-내부" "$SD_SRC" >/dev/null 2>&1 || true
  _lcp_quiet=1; [ "$_A_FAIL" -eq "$_A_SAVE_F" ] && _lcp_quiet=0
  _a_restore
  assert_eq "ok" "$(ok_if "$_lcp_quiet" CRIED)" \
    "[양성대조·언어기여] 라이브 목록에서 언어별 기여 검사가 실패했다 — 파생이나 확장자 필터가 깨졌나?"
}
sd_lang_contribution_control go
sd_lang_contribution_positive

# 소스 주석 축 — **실측 9건**(2026-09-04, 위 3건을 고친 뒤):
#   go/config.go:42 · java JwtValidator.java:38 · java KeycloakConfig.java:40 ·
#   kotlin config.kt:22 · node config.ts:26 · node jwt.ts:10 ·
#   python config.py:23 · rust config.rs:18 · rust config.rs:81
# ⚠️ 9는 **언어당 1건이 아니다**(6개 언어에 흩어져 있고 dotnet·php·ruby 는 0건) — 2절의 9와
# 우연히 같을 뿐이니 같은 뜻으로 읽지 말 것. 하한을 8로 두어 표현이 한 줄 바뀔 여지를 남긴다.
# ⚠️ **이 블록은 `sd_doc_axis` 를 복사한 인라인 루프였다**(값 비교 + 히트 하한이 두 벌). 다른 점은
# 코퍼스와 주석-줄 필터 둘뿐이라 인자로 접었다 — 이제 대조군 한 벌이 두 축을 다 덮는다.
sd_doc_axis "소스 주석" 'jwks[_ ]?min[_ ]?refetch|재조회|refetch' "$sd_expect" 8 \
  '(기본|default)[^0-9]{0,6}[0-9]' "$SD_SRC" '(//|#|\*|///)'

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

# --- 파생 반쪽 — 손 앵커 **밖**의 2차 자리를 트리에서 찾는다 -------------------
#
# ⚠️ **위 앵커 넷은 「이미 아는 자리」만 본다.** 원장 `guard-detection-surface-hand-narrowed`
# 의 (B) 부류가 이것이다 — **기존 언어에 새 자리가 생기면** 아무도 안 본다. 실측 2026-09-16:
# `node/src/jwt.ts` 에 `probeJwksMinRefetchSeconds = 60` 을 심고 이 가드를 돌리면 **SILENT**
# (`scripts/probe.sh`). 1절은 언어당 **한 파일 한 줄**만 `sed | head -1` 로 읽으므로 둘째 줄을
# 구조적으로 못 본다.
#
# 그래서 **값을 비교한다**: 트리의 SDK 소스 전체에서 이 두 파라미터에 **숫자 리터럴을 대입하는**
# 자리를 찾아, 그 값이 1절이 합의시킨 값과 같은지 본다. 「정의 자리는 하나」가 아니라
# 「어디에 적히든 값은 같다」를 요구하므로 정당한 2차 자리(내부 기본값·검증 분기)를 막지 않는다.
#
# ⚠️ **합의값을 여기 숫자로 적지 않는다** — 그러면 이 축 자신이 2차 정의 자리가 된다.
# `sd_expect`(JWKS 재조회) · `SD_EXPECT`(clock skew)는 1절이 아홉 언어에서 뽑아 서로 같음을
# 단언한 뒤 남긴 값이다.
#
# **오탐 실측(2026-09-16)**: `main` 최근 **300 커밋**(2026-08-14 ~ 오늘 = clock skew 30 합의
# 이후 전 구간)에서 합의값과 다른 값 **0 건**. 계측기가 실제로 잡는다는 대조군도 있다 —
# 전 이력 1102 커밋으로 넓히면 **664 커밋이 60 으로 걸린다**(30 합의 이전 시기). 즉 이 축은
# 침묵하는 것이 아니라 오늘 갈림이 없는 것이다.
#
# ⚠️ **정규식에 역슬래시를 쓰지 않는다** — `[.]` 로 적는다. 이번에도 `[A-Za-z0-9_?<>\[\]]` 가
# 세 겹 이스케이프에서 먹혀 python 의 `clock_skew: float = 30.0` 을 놓쳤다(실측).
# ⚠️ **꼬리를 `[A-Za-z_]*` 로 열어 두지 않는다 — 단위가 다른 이름이 걸린다.** 독립 레그가
# 지목했고 실측으로 재현했다: `jwksMinRefetchMs = 30_000` 은 **옳은 값인데** 30 과 달라
# required 체크를 빨갛게 한다. 그래서 꼬리를 **초 단위 접미사만** 받는 화이트리스트로 닫는다.
# ⚠️ 그 대가는 **거짓음성**이다 — 밀리초로 적힌 자리는 이 축이 안 본다. required 체크에서는
# 그쪽이 안전한 실패 방향이다(오탐 하나가 모든 PR 을 막는다). 새 접미사가 생기면 여기 더한다.
SD_2ND_SFX='([Ss]ec(ond)?s?|_sec(ond)?s?|SECONDS|SECS|IntervalSeconds)?'
SD_2ND_ID="([Jj]wks[_]?[Mm]in[_]?[Rr]efetch${SD_2ND_SFX}|JWKS_MIN_REFETCH(_SECONDS)?|[Mm]in[_]?[Rr]efetch${SD_2ND_SFX}|[Cc]lock[_]?[Ss]kew${SD_2ND_SFX}|CLOCK_SKEW|RefreshIntervalSeconds)"
# 식별자와 대입 사이에 낄 수 있는 것: 타입 표기(`: float` · ` int64`)와 C# 접근자(`{ get; init; }`).
# ⚠️ **토큰 시작 가드 — 이것이 없으면 다른 파라미터가 부분문자열로 걸린다.** 독립 레그가 두 번
# 블로킹으로 짚었고, 실측이 그 손을 들어 줬다: `AllowedClockSkew`·`MaxClockSkew`·`derivedClockSkew`
# ·`setMaxClockSkew`·`getClockSkew` 가 **오늘 트리에 이미 있다**(숫자 대입이 없어 아직 안 걸릴 뿐).
# ⚠️ 단순한 단어 경계로는 못 고친다 — `defaultJwksMinRefetchSecs` 가 정당한 camelCase 앞머리라
# 같은 모양이다. 그래서 **허용 앞머리를 열거**한다(`default`·`DEFAULT_`). 실측: 진짜 20 히트의
# 토큰 여덟 종은 전부 통과하고 위 다섯은 전부 차단된다.
# ⚠️ **이 가드가 사는 대가 — 거짓음성 하나를 안다.** 다른 앞머리를 단 토큰
# (`adminClockSkewSeconds = 60` · `probeJwksMinRefetchSeconds = 60`)은 **안 본다**. 실측
# (`scripts/probe.sh`): 그런 이름은 `SILENT`, **같은 토큰**(`jwksMinRefetchSeconds = 60`)은
# `CAUGHT`. 그 둘은 **어휘로 구분되지 않는다** — 앞머리가 붙은 이름은 「우리 값의 둘째 자리」일
# 수도 「다른 파라미터」일 수도 있고(오늘 트리의 `setMaxClockSkew`·`derivedClockSkew` 가 후자다),
# 판정할 수 없는 것을 required 체크가 판정하면 그 대가는 **모든 PR 차단**이다. 그래서 **모르는
# 것은 안 본다**. 같은 토큰을 다시 적는 것이 실제 2차 자리의 모양이고, 그것은 잡는다.
SD_2ND_GUARD='(^|[^A-Za-z0-9_])(default|DEFAULT_)?'
SD_2ND_MID='([[:space:]]*:[[:space:]]*[A-Za-z0-9_?<>.]+|[[:space:]]+[A-Za-z0-9_.]+)?([[:space:]]*[{][^}]*[}])?'
# 대입 우변: 벌거벗은 숫자 · TS 의 `?? 30` · JVM/.NET 의 `Duration.ofSeconds(30)`/`TimeSpan.FromSeconds(30)`.
SD_2ND_RHS='[[:space:]]*(=|:=|:|[?][?])[[:space:]]*("?[0-9][0-9._]*|(Duration[.]ofSeconds|TimeSpan[.]FromSeconds)[(][0-9][0-9._]*[)])'

# ⚠️ **`|while read` 를 쓰지 않는다** — 파이프의 오른쪽은 서브셸이라 `assert.sh` 의 실패 카운터가
# 증발한다(원장 `selftest-assert-counter-subshell`). 파일로 받아 리다이렉트로 읽는다.
# ⚠️ **`??` 는 대입이 아니라 「사용」일 수 있다** — 독립 레그가 지목했고 실측으로 재현했다:
# `const delay = clockSkew ?? 0` 은 옳은 코드인데 0 을 합의값과 비교당한다. 받는 것은 TS 의
# **정규화 관용**(`clockSkewSeconds: input.clockSkewSeconds ?? 30`)뿐이고, 그 모양은 한 줄에
# 식별자가 **두 번** 나온다. 나머지 대입 기호는 그대로 둔다.
# ⚠️ 필터를 함수로 둔 이유는 **대조군이 같은 경로를 타게** 하기 위함이다 — 아래 음성 대조군이
# 정규식만 시험하면 이 필터의 퇴화를 못 본다.
# ⚠️ **삼항 연산자의 `:` 는 대입이 아니다** — 독립 레그가 지목했고 실측으로 재현했다:
# `const v = enabled ? clockSkew : 0` 은 옳은 코드인데 0 을 합의값과 비교당한다. `??` 가 아닌
# 줄에서 `?` 를 담은 것은 전부 삼항(또는 TS 선택 프로퍼티)이라 뺀다 — 실측 2026-09-16:
# 오늘 히트 20 중 `?` 를 담은 줄은 **둘뿐이고 그 둘은 `??` 관용**이라 아래 분기로 간다.
sd_2nd_scan() { # stdin=파일 목록 → 필터를 거친 히트(`경로:줄:내용`)
  _a="$(mktemp)"
  xargs grep -nE "${SD_2ND_GUARD}${SD_2ND_ID}${SD_2ND_MID}${SD_2ND_RHS}" 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*(//|#|\*|/\*|--)' > "$_a" || true
  # ⚠️ **`?` 를 담았다고 다 빼면 거짓음성이 생긴다** — 실측: 꼬리 주석에 `? :` 가 있는 진짜
  # 2차 자리(`... = 60; // a ? b : c`)가 통째로 **SILENT** 였다. 삼항은 `?` 가 식별자 **앞**에
  # 오므로 그 모양만 뺀다.
  grep -vE '[?][?]' "$_a" | grep -vE "[[:space:]][?][[:space:]][^?]*${SD_2ND_ID}" || true
  grep -E '[?][?]' "$_a" | grep -E "${SD_2ND_GUARD}${SD_2ND_ID}.*${SD_2ND_ID}" || true
  rm -f "$_a"
}

# ⚠️ **면제표를 두지 않는다 — 한 번 뒀다가 지웠다.** 부분문자열 오탐을 표로 빠져나가게 하려
# 했는데, 위 **토큰 시작 가드**가 그 부류를 구조로 막자 표가 **한 번도 실행되지 않는 분기**로
# 남았다. required 체크 안의 죽은 분기는 자산이 아니라 부채다 — 빈 표라 매치가 0 이라 그 분기가
# 옳은지 아무도 모르고, 잘못 쓰면 **전부 면제**가 된다. 정당한 예외가 실제로 나타나면 그때
# **시험과 함께** 만든다.

# 음성 대조군 — 레그가 지목한 오탐 **둘**이 실제로 걸러지는가. 이 축은 required 체크 안에서
# 돌므로 오탐 하나가 모든 PR 을 막는다. 「안 걸린다」를 주석이 아니라 실행으로 고정한다.
sd_2nd_negative_control() {
  _nc="$(mktemp -d)"
  printf '  private static final long jwksMinRefetchMs = 30_000;\n' > "$_nc/Fp1.java"
  printf '  const delay = clockSkew ?? 0;\n' > "$_nc/fp2.ts"
  printf '  const v = enabled ? clockSkew : 0;\n' > "$_nc/fp3.ts"
  # 다른 파라미터가 부분문자열로 걸리는 자리 — 토큰 시작 가드가 막는다.
  printf '  public static readonly TimeSpan AllowedClockSkew = TimeSpan.FromSeconds(300);\n' > "$_nc/Fp4.cs"
  printf '  private const int MaxClockSkew = 300;\n  var derivedClockSkew = 300;\n' > "$_nc/Fp5.cs"
  _nc_hits="$(printf '%s\n%s\n%s\n%s\n%s\n' "$_nc/Fp1.java" "$_nc/fp2.ts" "$_nc/fp3.ts" "$_nc/Fp4.cs" "$_nc/Fp5.cs" | sd_2nd_scan | grep -c . || true)"
  rm -rf "$_nc"
  printf '%s' "$_nc_hits"
}
assert_eq "0" "$(sd_2nd_negative_control)" \
  "[2차 정의 자리] 오탐 대조군이 걸렸다 — 밀리초 이름(...Ms = 30_000) · 널병합 사용처(clockSkew ?? 0) · 삼항(enabled ? clockSkew : 0) 중 하나를 정의 자리로 읽는다(required 체크가 정당한 변경을 막는다)"

# 양성 대조군 — **진짜 모양은 걸려야 한다.** 위 음성 대조군만 있으면 「아무것도 안 잡는 패턴」이
# 만점을 받는다. 네 언어 관용을 모두 태워, 오탐을 막는다며 패턴을 좁히다가 진짜를 잃는 것을 막는다.
sd_2nd_positive_control() {
  _pc="$(mktemp -d)"
  printf '  public int clockSkewSeconds = 300;\n' > "$_pc/Pc.cs"
  printf '  const defaultJwksMinRefetchSecs int64 = 300\n' > "$_pc/pc.go"
  printf '    clock_skew: float = 300.0\n' > "$_pc/pc.py"
  printf '    clockSkewSeconds: input.clockSkewSeconds ?? 300,\n' > "$_pc/pc.ts"
  _pc_hits="$(printf '%s\n%s\n%s\n%s\n' "$_pc/Pc.cs" "$_pc/pc.go" "$_pc/pc.py" "$_pc/pc.ts" | sd_2nd_scan | grep -c . || true)"
  rm -rf "$_pc"
  printf '%s' "$_pc_hits"
}
assert_eq "4" "$(sd_2nd_positive_control)" \
  "[2차 정의 자리] 양성 대조군이 안 걸렸다 — 패턴이 좁아져 진짜 2차 자리를 못 본다(네 언어 관용: C# 대입 · Go 타입선언 · Python 타입주석 · TS 널병합)"

_2nd_tmp="$(mktemp)"
printf '%s\n' "$SD_SRC" | sd_2nd_scan > "$_2nd_tmp" || true

_2nd_n="$(grep -c . "$_2nd_tmp" || true)"
# 공허 하한 — 글롭·정규식이 깨지면 「갈림 없음」이 통과처럼 보인다. ⚠️ **오늘 값이 아니라
# 창 최저값을 박는다**(#443 의 판정): 최근 300 커밋에서 최소·최대 모두 **20**이었다.
SD_2ND_MIN=20
_2nd_enough=1; [ "$_2nd_n" -ge "$SD_2ND_MIN" ] && _2nd_enough=0
assert_eq "ok" "$(ok_if "$_2nd_enough" "$_2nd_n")" \
  "[2차 정의 자리] 대입 자리를 ${SD_2ND_MIN}개 미만 찾았다($_2nd_n) — 정규식이나 소스 목록이 깨졌나?"

# 언어별 기여 — 한 언어가 통째로 빠지는 것을 총합 하한은 못 본다(2b 축이 같은 이유로 배운 것).
_2nd_langs="$(cut -d/ -f1 "$_2nd_tmp" | sort -u | tr '\n' ' ')"
_2nd_missing=''
for L in $SD_LANGS; do
  case " $_2nd_langs " in *" $L "*) ;; *) _2nd_missing="$_2nd_missing $L" ;; esac
done
assert_eq "" "$_2nd_missing" \
  "[2차 정의 자리] 대입 자리를 하나도 못 찾은 언어가 있다 —$_2nd_missing (그 언어의 표기가 바뀌었나?)"

while IFS= read -r _2nd_line; do
  [ -n "$_2nd_line" ] || continue
  _2nd_where="$(printf '%s' "$_2nd_line" | cut -d: -f1,2)"
  _2nd_raw="$(printf '%s' "$_2nd_line" | grep -oE "${SD_2ND_ID}${SD_2ND_MID}${SD_2ND_RHS}" \
    | grep -oE '[0-9][0-9._]*[)]?$' | tr -d ')' | head -1)"
  # ⚠️ **추출 실패를 통과로 읽지 않는다**(독립 레그 지목 · 1b 축이 같은 이유로 이미 배운 것).
  # 조용히 `continue` 하면 그 줄이 공허 하한과 언어별 기여에는 **세어지면서** 값은 안 본다.
  _2nd_got=1; [ -n "$_2nd_raw" ] && _2nd_got=0
  assert_eq "ok" "$(ok_if "$_2nd_got" 'NO-VALUE')" \
    "[2차 정의 자리] $_2nd_where 에서 값을 못 뽑았다 — 이 줄이 하한에는 세어지고 값은 안 보인다"
  [ -n "$_2nd_raw" ] || continue
  case "$_2nd_line" in
    *[Ss]kew*|*SKEW*) _2nd_exp="$SD_EXPECT"; _2nd_fam='clock skew' ;;
    *)                _2nd_exp="$sd_expect"; _2nd_fam='JWKS 재조회' ;;
  esac
  assert_eq "$(sd_norm "$_2nd_exp")" "$(sd_norm "$_2nd_raw")" \
    "[2차 정의 자리] $_2nd_where 의 $_2nd_fam 리터럴이 1절이 합의시킨 값과 다르다 — 한 자리만 갈려도 그 경로에서만 동작이 달라진다"
done < "$_2nd_tmp"
rm -f "$_2nd_tmp"

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
  # ⚠️ **메시지 없는 `assert_ok` 는 실패해도 무엇이 틀렸는지 안 알려준다** — 실측(2026-09-14):
  # 하한을 `-ge 2` 로 올린 변이가 낸 전부가 `FAIL expected success: test 1 -ge 2` 세 줄이었고,
  # **어느 파일인지 어느 축인지가 없다**(호출이 셋이라 세 줄이 똑같다).
  _ohit=1; [ "$_n" -ge 1 ] && _ohit=0
  assert_eq "ok" "$(ok_if "$_ohit" "$_n")" \
    "[소유자축] $1 에서 이 불변식을 말하는 줄을 못 찾았다 — 정규식이 낡았나? (/$2/)"
  _bad="$(printf '%s\n' "$_lines" | grep -vE "(^|[^0-9])$SD_POLICY([^0-9]|$)" || true)"
  assert_eq "" "$_bad" "$1 이 정책값 $SD_POLICY 을 말하지 않는 줄로 이 불변식을 서술한다"
}
sd_owner_axis "CLAUDE.md" 'JWKS 재조회 최소 간격'
sd_owner_axis ".claude/rules/security.md" 'JWKS minimum refetch interval defaults'
sd_owner_axis ".claude/rules/security.md" 'is the same invariant and is likewise'

# ⚠️ **소유자 축은 단언이 셋이고 셋 다 공허했다** — 실측(2026-09-14, `scripts/probe.sh --site`):
# 존재 검사(`_exists=0`)·히트 하한(`-ge 0`)·값 비교(`_bad=""`) 를 각각 무력화하니 **셋 다 SILENT**.
# 그래서 대조군도 셋이다. **한 대조군이 단언 둘을 덮을 수 없다** — 「실패가 늘었는가」만 보는
# 대조군은 *어느* 단언이 울었는지 구분하지 않아, 살아 있는 단언 하나가 죽은 단언을 가린다
# (#495 가 문서 축에서 실측한 부류다). 그래서 각 대조군은 **그 단언만 울릴 수 있는 입력**을 쓴다.
#
# ⚠️ 트리를 복사하지 않는다 — 파일 하나만 같은 상대경로로 TMP 에 놓고 `ROOT` 를 그리로 돌린다.
# 여기서 나는 실패는 **기대된 실패**라 계수를 원복한다(스위트를 빨갛게 만들면 안 된다).
# ⚠️ **`set -eu` 아래다 — 반환값을 `cmd; v=$?` 로 받지 말 것.** 비제로가 곧 스크립트 종료라
# 스위트가 **출력 한 줄 없이 exit 1** 로 죽는다(실측). 반드시 `|| v=1` 조건 문맥으로 받는다.
sd_owner_probe() { # $1=TMP루트 $2=파일 $3=정규식 → 실패가 늘었으면 0
  _a_save; _op_root="$ROOT"
  ROOT="$1"
  # ⚠️ `|| true` 는 지금은 불필요하다(실측: `assert_*` 는 if/fi 로 끝나 항상 0 을 낸다).
  # 미래에 `assert_*` 가 비교 결과를 반환하게 되면 `set -e` 가 아래 원복을 건너뛴다 — 독립
  # 레그가 지목한 자리라 값싼 보험으로 둔다(원복이 새면 계수와 ROOT 가 함께 샌다).
  sd_owner_axis "$2" "$3" >/dev/null 2>&1 || true
  ROOT="$_op_root"
  _op_grew=1; [ "$_A_FAIL" -gt "$_A_SAVE_F" ] && _op_grew=0
  _a_restore
  return "$_op_grew"
}

# (1) **값 비교** — 정책값만 다른 사본. 그 줄은 여전히 있으므로 존재·하한은 통과하고,
#     값 비교만 울 수 있다.
sd_owner_value_control() { # $1=파일 $2=정규식 $3=sed표현식
  _ovc_tmp="$(mktemp -d)"; mkdir -p "$_ovc_tmp/$(dirname "$1")"
  sed "$3" "$ROOT/$1" > "$_ovc_tmp/$1"
  _ovc_grew=0; sd_owner_probe "$_ovc_tmp" "$1" "$2" || _ovc_grew=1
  rm -rf "$_ovc_tmp"
  assert_eq "ok" "$(ok_if "$_ovc_grew" DID-NOT-FAIL)" \
    "[값대조·소유자축] $1: 정책값을 다르게 말하는 사본에서도 축이 통과했다 — 값 비교가 no-op 이다"
}

# (2) **히트 하한** — 그 줄만 지운 사본. ⚠️ **값 단언은 「안 도는」 것이 아니라 「돌지만 침묵」한다**
#     — 독립 레그가 내 첫 주석을 반박했고 실측이 그쪽을 편들었다: `_lines=""` 이면
#     `printf` 가 빈 줄 하나를 내고 `grep -v` 가 그것을 고르지만 명령치환이 끝 개행을
#     깎아 `_bad=""` 가 된다(`_n=0` · `_bad` 길이 0). 결과적으로 **하한만 울 수 있다**는 결론은
#     같지만, 이유가 다르면 다음 사람이 틀린 모형으로 이 자리를 고친다.
sd_owner_floor_control() { # $1=파일 $2=정규식
  _ofc_tmp="$(mktemp -d)"; mkdir -p "$_ofc_tmp/$(dirname "$1")"
  grep -vE "$2" "$ROOT/$1" > "$_ofc_tmp/$1" || true
  _ofc_grew=0; sd_owner_probe "$_ofc_tmp" "$1" "$2" || _ofc_grew=1
  rm -rf "$_ofc_tmp"
  assert_eq "ok" "$(ok_if "$_ofc_grew" DID-NOT-FAIL)" \
    "[하한대조·소유자축] $1: 그 줄이 하나도 없는 사본에서도 축이 통과했다 — 히트 하한이 no-op 이다"
}

# (3) **존재 검사** — 파일이 없는 빈 루트. 존재가 실패하면 축은 거기서 `return` 하므로
#     뒤의 둘은 안 돌고, 존재만 울 수 있다.
sd_owner_exists_control() { # $1=파일 $2=정규식
  _oec_tmp="$(mktemp -d)"
  _oec_grew=0; sd_owner_probe "$_oec_tmp" "$1" "$2" || _oec_grew=1
  rm -rf "$_oec_tmp"
  assert_eq "ok" "$(ok_if "$_oec_grew" DID-NOT-FAIL)" \
    "[존재대조·소유자축] $1: 파일이 없는 루트에서도 축이 통과했다 — 존재 검사가 no-op 이다"
}

# ⚠️ **양성 대조** — 라이브 루트에서는 셋 다 조용해야 한다. 없으면 「늘 운다」와 구분되지 않는다.
sd_owner_positive_control() { # $1=파일 $2=정규식
  _opc_grew=0; sd_owner_probe "$ROOT" "$1" "$2" || _opc_grew=1
  _opc_quiet=1; [ "$_opc_grew" -eq 1 ] && _opc_quiet=0
  assert_eq "ok" "$(ok_if "$_opc_quiet" CRIED)" \
    "[양성대조·소유자축] $1: 라이브 루트에서 축이 실패했다 — 문서가 정책값을 안 말하거나 정규식이 낡았다"
}

sd_owner_value_control  'CLAUDE.md' 'JWKS 재조회 최소 간격' 's/9개 언어 전부 30초/9개 언어 전부 47초/'
sd_owner_floor_control  'CLAUDE.md' 'JWKS 재조회 최소 간격'
sd_owner_exists_control 'CLAUDE.md' 'JWKS 재조회 최소 간격'
sd_owner_positive_control 'CLAUDE.md' 'JWKS 재조회 최소 간격'
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


# ⚠️ **음성 대조군 — 축의 *비교*가 실제로 도는가.** `sd_doc_axis` 는 「지금 문서가 맞다」만 본다.
# 그 형태는 **비교가 no-op 이어도 통과한다** — 실측(2026-09-13, `scripts/probe.sh`): `_bad=""` 로
# 무력화하니 **SILENT** 였다(하한은 히트 **수**만 세므로 그대로 통과한다).
#
# ⚠️ **대조군 안에 탐지를 다시 구현하지 말 것.** 첫 판이 그랬고 같은 변이가 **여전히 SILENT**
# 였다 — 축의 비교가 아니라 나란한 grep 을 태웠기 때문이다(실측). 그래서 이 대조군은
# **`sd_doc_axis` 자신**을 값이 틀린 사본 트리에 대고 돌리고, 실패 계수가 늘었는지 본다.
# 계수는 되돌린다 — 여기서 나는 실패는 **기대된 실패**라 스위트를 빨갛게 만들면 안 된다.
sd_doc_negative_control() { # $1=라벨 $2=상대경로 $3=sed $4=파라미터re $5=기대값 $6=신호re $7=중간필터re
  _dnc_tmp="$(mktemp -d)"
  mkdir -p "$_dnc_tmp/$(dirname "$2")"
  sed "$3" "$ROOT/$2" > "$_dnc_tmp/$2"
  _a_save
  _dnc_root="$ROOT"; ROOT="$_dnc_tmp"
  sd_doc_axis "음성대조-내부" "$4" "$5" 1 "$6" "$2" "${7:-.}" >/dev/null 2>&1 || true
  ROOT="$_dnc_root"
  _dnc_grew=1; [ "$_A_FAIL" -gt "$_A_SAVE_F" ] && _dnc_grew=0
  _a_restore
  rm -rf "$_dnc_tmp"
  assert_eq "ok" "$(ok_if "$_dnc_grew" DID-NOT-FAIL)" \
    "[음성대조·값비교] $1: 코드값과 **다른 값**을 말하는 사본에서도 축이 통과했다 — 비교가 no-op 이거나 탐지 패턴이 낡았다"
}

# ⚠️ **양성 대조도 함께** — 「늘 뭔가 찾는다」와 구분한다. 같은 축을 **라이브** 트리에 대고
# 돌려 실패가 **안 늘어야** 한다. 둘을 합치면 축은 "틀리면 운다 · 맞으면 안 운다"를 다 보인다.
sd_doc_positive_control() { # $1=라벨 $2=상대경로 $3=파라미터re $4=기대값 $5=신호re $6=중간필터re
  _a_save
  sd_doc_axis "양성대조-내부" "$3" "$4" 1 "$5" "$2" "${6:-.}" >/dev/null 2>&1 || true
  _dpc_quiet=1; [ "$_A_FAIL" -eq "$_A_SAVE_F" ] && _dpc_quiet=0
  _a_restore
  assert_eq "ok" "$(ok_if "$_dpc_quiet" CRIED)" \
    "[양성대조·값비교] $1: 라이브 $2 에서 축이 실패했다 — 코드값을 안 말하거나 신호가 낡았다"
}

sd_dnc_param='jwks[_ ]?min[_ ]?refetch|RefreshIntervalSeconds'
sd_dnc_signal='default|기본값|minimum interval|throttled|cooldown|^[0-9]+:\|'

sd_doc_negative_control 'JWKS 재조회' 'go/README.md' 's/(default 30s)/(default 47s)/' \
  "$sd_dnc_param" "$sd_expect" "$sd_dnc_signal"
sd_doc_positive_control 'JWKS 재조회' 'go/README.md' "$sd_dnc_param" "$sd_expect" "$sd_dnc_signal"

# ⚠️ **하한 전용 음성 대조군 — 축에는 단언이 둘이고 대조군은 하나만 덮었다.** 위 음성 대조군은
# 「값이 틀리면 운다」만 보인다. 실측(2026-09-14, `scripts/probe.sh`): 하한 대입을 `_enough=0` 으로
# 무력화하니 **SILENT** 였다 — 위 대조군은 *어느* 단언이 울었는지 구분하지 않아 값 비교가 살아
# 있으면 그것만으로 통과한다. 독립 레그(Grok)도 같은 자리를 지목했다.
# 그래서 **하한만 울 수 있는 입력**으로 한 번 더 태운다: 빈 문서 → 히트 0 → 하한(1) 미달.
# 값 단언은 훑을 줄이 없어 아예 돌지 않으므로, 여기서 나는 실패는 **하한의 것뿐**이다.
sd_doc_floor_control() { # $1=라벨 $2=파라미터re $3=기대값 $4=신호re
  _dfc_tmp="$(mktemp -d)"
  : > "$_dfc_tmp/EMPTY.md"
  _a_save
  _dfc_docs="$SD_DOCS"; _dfc_root="$ROOT"
  SD_DOCS="EMPTY.md"; ROOT="$_dfc_tmp"
  sd_doc_axis "하한대조-내부" "$2" "$3" 1 "$4" >/dev/null 2>&1
  SD_DOCS="$_dfc_docs"; ROOT="$_dfc_root"
  _dfc_grew=1; [ "$_A_FAIL" -gt "$_A_SAVE_F" ] && _dfc_grew=0
  _a_restore
  rm -rf "$_dfc_tmp"
  assert_eq "ok" "$(ok_if "$_dfc_grew" DID-NOT-FAIL)" \
    "[하한대조·문서축] $1: 아무 줄도 못 찾은 트리에서도 축이 통과했다 — 히트 하한이 no-op 이다"
}
sd_doc_floor_control 'JWKS 재조회' "$sd_dnc_param" "$sd_expect" "$sd_dnc_signal"

# ⚠️ **소스 주석 축도 같은 축을 쓰므로 같은 대조군을 코퍼스만 바꿔 태운다.** 히트 하한은 축에
# 한 벌뿐이라 위 `sd_doc_floor_control` 하나가 두 코퍼스를 다 덮는다(복제를 지운 값이다).
sd_src_param='jwks[_ ]?min[_ ]?refetch|재조회|refetch'
sd_src_signal='(기본|default)[^0-9]{0,6}[0-9]'
sd_src_mid='(//|#|\*|///)'
sd_doc_negative_control '소스 주석' 'go/config.go' 's/default 30)/default 45)/' \
  "$sd_src_param" "$sd_expect" "$sd_src_signal" "$sd_src_mid"
sd_doc_positive_control '소스 주석' 'go/config.go' \
  "$sd_src_param" "$sd_expect" "$sd_src_signal" "$sd_src_mid"
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
# ⚠️ **손 목록은 파생과 대조돼야 한다.** `SD_LANGS` 는 위에서 트리 파생(`sd_tree_langs`)과
# 대조되지만 이 목록은 아무와도 대조되지 않았다 — 열 번째 언어가 들어오면 이 축을 **조용히**
# 건너뛴다(루프가 그 이름을 모르니 토큰 타입 계약이 없어도 통과한다). 두 목록이 같아야 한다.
assert_eq "$(sd_sorted "$SD_LANGS")" "$(sd_sorted "$SD_TOKEN_TYPE_LANGS")" \
  "[토큰타입] SD_TOKEN_TYPE_LANGS 가 SD_LANGS 와 다르다 — 언어가 들고 났는데 이 축의 손 목록이 안 따라왔다"
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
