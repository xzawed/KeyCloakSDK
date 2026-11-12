#!/usr/bin/env sh
# 레인 카나리아 — 보안 기본값 가드(`test-security-defaults.sh`) **밖**의 시험 묶음이 그 레인 실행에서 돌아 통과했는가를
# 레인의 `scripts/check-canaries-ran.mjs` 가 시험 보고서로 대조할 때 읽는 표. 두 묶음이다:
#   dump   — 도달 가능한 객체 전부의 기본 표현이 비밀을 찍지 않는다(덤프 걷기 · #592–#602)
#   bearer — admin Bearer 문법의 정본 표 스물(축 1g 가 행 id 를, 이 표가 그 표를 도는 시험을)
#
# 왜 가드 밖인가: 아홉 적대 경로 행렬의 W1 이 가드의 `파일|선언` 행을 **전부** 뽑아 자기 손 목록에 요구한다 — 가드에 이
# 행을 더하면 아홉 행렬이 그 시험의 대상 · 계급까지 손 목록에 적어야 한다. 그리고 등록부 처방이 「가드에 축을 더하지
# 않는다」다(`guard-detection-surface-hand-narrowed`). 판정 방식은 가드의 카나리아와 같다 — 레인 보고서에 항목이 있고
# 건너뛰지 않았고 통과했다(매개변수 시험은 항목 전부). 등록부의 「덤프 걷기 실행 attest」를 nonce attest 가 아니라 이
# 대조로 닫은 까닭(Grok 레그 대조): 레인이 이미 이 검사를 조건 없이 돌고 배선 가드가 그 단계를 지키며, 시험 코드를
# 고치지 않는다. attest 만 잡는 것 — 같은 실행의 보고서가 아닌 재생(레인은 새 체크아웃 · go `-count=1`)과 걷기가 빈
# 집합인 것(시험 자신이 단언한다) — 은 남는다.
#
# 이 파일 자신의 단언(required `doc-facts`): 트리의 언어마다 두 표 다 행이 있고(열 번째 언어는 여기서 운다), 행은 그
# 언어 디렉터리 안의 `파일|선언` 이고 그 묶음의 파일(덤프 걷기 파일 · 가드가 아는 bearer 시험표) 안이며, 언어마다 행
# 수가 `lc_rows` 와 같고, 검사기의 해석(`--list` — 주석 밖 정확히 한 줄 · 선언 자리 · 두 행이 한 시험 아님 · 자리표시
# 제목의 꼴에 맞는 다른 문자열 없음)이 아홉 언어 다 성공한다.
# ⚠️ 표 함수는 검사기가 **그대로 실행**한다 — 줄 머리 `이름() {` · 줄 머리 `}` 모양을 지키고, 정의 밖의 무엇(헬퍼 ·
# 변수)에 기대지 않는다. 새 표 함수(`lc_*_canary`)는 검사기 AXES 에 더한다(정의 수가 다르면 판정 불가).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
. "$DIR/assert.sh"
. "$ROOT/scripts/lib/deploy-facts.sh"

lc_dump_canary() {
  case "$1" in
    java)   printf '%s\n' 'java/keycloak-sdk/src/test/java/io/github/xzawed/keycloak/FacadeDumpTest.java|void reachableObjectsDoNotRenderSecrets(' ;;
    kotlin) printf '%s\n' 'kotlin/src/test/kotlin/io/github/xzawed/keycloak/FacadeDumpTest.kt|fun `reachable objects do not render secrets on the floor paths`(' ;;
    python) printf '%s\n' 'python/tests/unit/test_facade_dump.py|def test_reachable_objects_do_not_render_secrets(' ;;
    node)   printf '%s\n' \
              "node/test/unit/facade-dump.test.ts|it('바닥 경로 넷이 어떤 카나리아도 원문으로 찍지 않는다'" \
              "node/test/unit/facade-dump.test.ts|it('알려진 누출 표의 항목이 전부 아직 관측된다'" \
              "node/test/unit/facade-dump.test.ts|it('src 의 클래스 선언 전부가 걷기에 닿거나 이유와 함께 면제된다'" ;;
    go)     printf '%s\n' 'go/facade_dump_test.go|func TestReachableObjectsDoNotRenderSecrets(' ;;
    dotnet) printf '%s\n' 'dotnet/tests/Xzawed.Keycloak.Sdk.Tests/FacadeDumpTests.cs|public async Task Reachable_objects_do_not_render_secrets(' ;;
    php)    printf '%s\n' 'php/tests/Unit/FacadeDumpTest.php|public function testReachableObjectsDoNotDumpSecrets(' ;;
    rust)   printf '%s\n' \
              'rust/tests/facade_dump.rs|async fn reachable_objects_do_not_render_secrets(' \
              'rust/tests/facade_dump.rs|fn scanner_reads_the_shapes_the_reconcile_relies_on(' ;;
    ruby)   printf '%s\n' \
              'ruby/spec/unit/facade_dump_spec.rb|it "plants every canary into its root through the public API (flow check)"' \
              'ruby/spec/unit/facade_dump_spec.rb|it "renders no secret on #inspect, #to_s, #pretty_inspect (or an error'"'"'s #full_message)"' \
              'ruby/spec/unit/facade_dump_spec.rb|it "reaches every declared SDK class, or excludes it by rule, or exempts it with a reason"' \
              'ruby/spec/unit/facade_dump_spec.rb|it "derives the same declared types at runtime as ruby/lib declares in source"' \
              'ruby/spec/unit/facade_dump_spec.rb|it "never walks into the harness'"'"'s own objects (example, scene, webmock stubs)"' \
              'ruby/spec/unit/facade_dump_spec.rb|it "sees a canary when a carrier does print one (the detector is not blind)"' ;;
  esac
}

lc_bearer_canary() {
  case "$1" in
    java)   printf '%s\n' 'java/keycloak-sdk-admin/src/test/java/io/github/xzawed/keycloak/admin/BearerTokenGrammarTest.java|void theCanonicalTable_throughTheFacade_raw_andBothGrants(' ;;
    kotlin) printf '%s\n' 'kotlin/src/test/kotlin/io/github/xzawed/keycloak/admin/BearerTokenGrammarTest.kt|fun `the canonical table through the facade, raw and both grants`(' ;;
    python) printf '%s\n' \
              'python/tests/unit/test_admin_bearer_header.py|def test_the_rule_oracle_agrees_with_the_canonical_table(' \
              'python/tests/unit/test_admin_bearer_header.py|def test_the_sdk_predicate_agrees_with_the_rule(' \
              'python/tests/unit/test_admin_bearer_header.py|async def test_the_canonical_table_through_the_sdk_grant(' \
              'python/tests/unit/test_admin_bearer_header.py|async def test_the_canonical_table_through_an_injected_bearer(' \
              'python/tests/unit/test_admin_bearer_header.py|async def test_the_sweep_is_judged_by_the_bearer_rule(' ;;
    node)   printf '%s\n' \
              'node/test/unit/admin-bearer-header.test.ts|it.each(SENT)(`%s — ${route} 가 뗀 값을 보낸다`' \
              'node/test/unit/admin-bearer-header.test.ts|it.each(REJECTED)(`%s — ${route} 가 요청 없이 거부한다`' \
              "node/test/unit/admin-bearer-header.test.ts|'%s — 생성 때의 토큰 확보(AdminClient.create)'" \
              "node/test/unit/admin-bearer-header.test.ts|'%s — 공개 provider(소비자 TokenSource)는 뗀 값을 캐시하고, 거부한 값은 캐시하지 않는다'" \
              "node/test/unit/admin-bearer-header.test.ts|'%s — SDK provider(AuthClient · 가짜 IdP)는 거부한 값을 캐시하지 않는다(IdP 에 다시 묻는다)'" ;;
    go)     printf '%s\n' \
              'go/bearer_grammar_test.go|func TestBearerGrammarOnAFacadeCall(' \
              'go/bearer_grammar_test.go|func TestBearerGrammarOnTheRawPut(' \
              'go/bearer_grammar_test.go|func TestBearerGrammarAtInjectedConstruction(' \
              'go/bearer_grammar_test.go|func TestBearerGrammarOnTheSDKGrant(' \
              'go/bearer_grammar_test.go|func TestBearerGrammarOnThePublicProvider(' ;;
    dotnet) printf '%s\n' \
              'dotnet/tests/Xzawed.Keycloak.Sdk.Tests/BearerTokenGrammarTests.cs|public async Task A_consumer_token_goes_out_on_every_admin_route_only_under_the_grammar(' \
              'dotnet/tests/Xzawed.Keycloak.Sdk.Tests/BearerTokenGrammarTests.cs|public async Task The_sdk_admin_caches_only_a_grant_under_the_grammar(' \
              'dotnet/tests/Xzawed.Keycloak.Sdk.Tests/BearerTokenGrammarTests.cs|public async Task The_token_provider_does_not_cache_a_token_outside_the_grammar(' ;;
    php)    printf '%s\n' \
              'php/tests/Unit/Admin/AdminBearerGrammarTest.php|public function testTheFacadeTakesOnlyAGrantUnderTheGrammarAndCachesNoOther(' \
              'php/tests/Unit/Admin/AdminBearerGrammarTest.php|public function testRawGetsTheLowerLibraryErrorForARefusedGrant(' \
              'php/tests/Unit/Admin/AdminBearerGrammarTest.php|public function testThePredicate(' \
              'php/tests/Unit/Admin/AdminBearerGrammarTest.php|public function testTheTokenProviderCachesOnlyATokenUnderTheGrammar(' ;;
    rust)   printf '%s\n' \
              'rust/tests/bearer_grammar.rs|async fn facade_sends_the_trimmed_b64token_or_refuses_without_a_request(' \
              'rust/tests/bearer_grammar.rs|async fn raw_sends_the_trimmed_b64token_or_refuses_without_a_request(' \
              'rust/tests/bearer_grammar.rs|async fn sdk_provider_caches_the_trimmed_token_and_never_a_refused_one(' \
              'rust/tests/bearer_grammar.rs|async fn default_client_sends_the_trimmed_b64token_or_refuses_without_a_request(' ;;
    ruby)   printf '%s\n' \
              'ruby/spec/unit/bearer_grammar_spec.rb|it "#{id}: #{row.want ? "sends #{row.want[0, 16].inspect}"' \
              'ruby/spec/unit/bearer_grammar_spec.rb|it "#{id}: #{row.want ? '"'"'caches the trimmed token and sends it'"'"'' \
              'ruby/spec/unit/bearer_grammar_spec.rb|it "#{id}: the provider itself' ;;
  esac
}

# 행이 그 묶음의 파일 안에 있고 그 수가 표와 같은가 — 행 하나를 지우거나 다른 파일의 시험으로 돌려 대고 진짜 시험을
# 건너뛰면 초록이었다(#1033 레그 R1 · R2). bearer 표 파일은 가드의 축 1g 가 언어마다 이미 아는 것(`sd_bearer_table` — 정의를
# 떼어 그대로 실행한다, 사본 없음)이고, 덤프 걷기 파일은 아래 표다. 행 수는 손으로 고정한다 — 시험을 더하거나 빼면 행과
# 이 수를 함께 고친다(한 줄 지우기가 조용히 지나가지 않게).
lc_dump_file() {
  case "$1" in
    java)   printf '%s' 'java/keycloak-sdk/src/test/java/io/github/xzawed/keycloak/FacadeDumpTest.java' ;;
    kotlin) printf '%s' 'kotlin/src/test/kotlin/io/github/xzawed/keycloak/FacadeDumpTest.kt' ;;
    python) printf '%s' 'python/tests/unit/test_facade_dump.py' ;;
    node)   printf '%s' 'node/test/unit/facade-dump.test.ts' ;;
    go)     printf '%s' 'go/facade_dump_test.go' ;;
    dotnet) printf '%s' 'dotnet/tests/Xzawed.Keycloak.Sdk.Tests/FacadeDumpTests.cs' ;;
    php)    printf '%s' 'php/tests/Unit/FacadeDumpTest.php' ;;
    rust)   printf '%s' 'rust/tests/facade_dump.rs' ;;
    ruby)   printf '%s' 'ruby/spec/unit/facade_dump_spec.rb' ;;
  esac
}
lc_rows() { # 언어 → `덤프 bearer` 행 수
  case "$1" in
    java)   printf '1 1' ;;
    kotlin) printf '1 1' ;;
    python) printf '1 5' ;;
    node)   printf '3 5' ;;
    go)     printf '1 5' ;;
    dotnet) printf '1 3' ;;
    php)    printf '1 4' ;;
    rust)   printf '2 4' ;;
    ruby)   printf '6 3' ;;
  esac
}

# ─── 이 파일의 단언 ─────────────────────────────────────────────────────────────────────────────────────
eval "$(sed -n '/^sd_bearer_table() {/,/^}/p' "$ROOT/scripts/test/test-security-defaults.sh")"
assert_eq "ok" "$(command -v sd_bearer_table >/dev/null 2>&1 && printf ok || printf MISSING)" "[레인 카나리아] 가드에서 sd_bearer_table 정의를 못 떼었다 — 모양(줄 머리 정의 · 줄 머리 })이 바뀌었나?"
LC_LANGS="$(df_tree_langs)"
_seen=0
for L in $LC_LANGS; do
  _counts=''
  for _fn in lc_dump_canary lc_bearer_canary; do
    _rows="$($_fn "$L")"
    assert_eq "ok" "$([ -n "$_rows" ] && printf ok || printf MISSING)" "[레인 카나리아] $L 의 $_fn 행이 없다 — 열 번째 언어면 그 언어의 시험을 적어라"
    if [ "$_fn" = lc_dump_canary ]; then _home="$(lc_dump_file "$L")"; else _home="$(sd_bearer_table "$L")"; fi
    _n=0
    while IFS= read -r _r; do
      [ -n "$_r" ] || continue
      _n=$((_n + 1))
      _f="${_r%%|*}"; _d="${_r#*|}"
      _shape=bad; [ "$_d" != "$_r" ] && [ -n "$_d" ] && [ "${_f#"$L"/}" != "$_f" ] && _shape=ok
      assert_eq "ok" "$_shape" "[레인 카나리아] $L 의 $_fn 행이 \`$L/…|선언\` 이 아니다: $_r"
      assert_eq "${_home:-(그 언어의 파일이 표에 없다)}" "$_f" "[레인 카나리아] $L 의 $_fn 행이 그 묶음의 파일 밖을 가리킨다: $_r"
    done <<EOF
$_rows
EOF
    _counts="$_counts${_counts:+ }$_n"
  done
  assert_eq "$(lc_rows "$L")" "$_counts" "[레인 카나리아] $L 의 행 수(덤프 bearer)가 lc_rows 와 다르다 — 시험을 더하거나 뺐으면 둘을 함께 고친다"
  _out="$(node "$ROOT/scripts/check-canaries-ran.mjs" --lang "$L" --list 2>&1)" && _rc=0 || _rc=$?
  assert_eq "0" "$_rc" "[레인 카나리아] $L 의 카나리아 해석이 실패했다 — 출력: $_out"
  _seen=$((_seen + 1))
done
assert_eq "ok" "$([ "$_seen" -ge 1 ] && printf ok || printf EMPTY)" "[레인 카나리아] 트리에서 언어를 하나도 못 읽었다 — 공허하다"
assert_report
