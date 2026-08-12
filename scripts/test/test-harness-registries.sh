#!/usr/bin/env sh
# 하네스 로컬 레지스트리 설정 가드 — 현재 겨누는 것은 verdaccio(node) 하나다.
#
# 왜 이 가드가 필요한가: `harness/install/registries/verdaccio.yaml`의 `@xzawed/*` 블록은
# **없어도 아무 테스트가 깨지지 않는 채로** 야간 `install-all`만 조용히 빨개진다. 실제로 그랬다 —
# 2026-08-07 14:19 `node-v0.1.0-rc.2`가 npmjs로 나가고, 다음 야간 실행부터 3연속(08-08·08-09·08-10)
# node가 `E409 … this package is already present`로 죽었다. 리포에는 아무 변경이 없었고 리포를
# 겨누는 가드는 전부 초록이었다 — 저장소 밖(레지스트리)에서 상태가 변해 설정이 낡은 것이다.
#
# ⚠️ 이 가드가 막는 드리프트는 넷이고, 전부 "고치는 것처럼 보이는 편집"이다:
#   (1) `@xzawed/*`에 `proxy: npmjs`를 "일관성 있게" 추가        → E409 재발
#   (2) `@*/*`를 `@xzawed/*`보다 위로 이동(Verdaccio는 첫 매치) → E409 재발
#   (3) `@xzawed/*` 블록 자체를 정리하다 삭제                    → E409 재발
#   (4) `@*/*`·`**`에서 `proxy: npmjs`를 "격리"하려고 제거       → 전이 의존성 해석 불가(반대 방향 고장)
# 그래서 어서션은 **양방향이다** — 자기 스코프엔 proxy가 없어야 하고, 나머지 둘엔 있어야 한다.
# 한쪽만 검사하면 (4)를 통과시킨다.
#
# ⚠️ 스코프는 하드코딩하지 않고 `node/package.json`의 `name`에서 파생한다. 하드코딩하면 패키지
# 스코프를 바꿀 때 이 가드가 **낡은 스코프를 계속 지키며 초록**이 되어, 정작 새 스코프는 무방비로
# uplink에 물린다(가드가 있다는 사실이 오히려 안심시키는 부류).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$DIR/../.."
CFG="$ROOT/harness/install/registries/verdaccio.yaml"
PKG="$ROOT/node/package.json"

assert_ok test -f "$CFG"
assert_ok test -f "$PKG"

# npm 스코프(`@xzawed`)를 SSOT에서 파생.
SCOPE="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(@[^"/]*\)\/.*/\1/p' "$PKG" | head -1)"
assert_ok test -n "$SCOPE"
[ -n "$SCOPE" ] || { assert_report; exit 1; }

# packages: 매핑을 순서대로 훑어 "순번<TAB>패턴<TAB>proxy유무"를 뽑는다.
#
# ⚠️ **첫 줄에서 CR을 떼고 시작한다 — Windows 워킹트리 때문이다.** 이 저장소의
# `.gitattributes`는 `*.sh`·gradlew에만 `eol=lf`를 걸고 `*.yaml`에는 걸지 않는다. 그래서
# `core.autocrlf=true`(Windows 흔한 기본값) 기여자의 워킹트리에서 이 yaml은 **CRLF**가 된다
# (실측: `verdaccio.yaml` 68 CR · 기존 `compose.install.yml` 196 CR — blob은 셋 다 0 CR이라
# CI 체크아웃은 LF다). 이게 조용한 이유는 Git Bash의 gawk·sed가 CR을 **말없이 떼기** 때문이다 —
# 로컬은 10/10 초록인데 같은 파일을 컨테이너(mawk)에 물리면 모든 줄 길이가 +1이 되어 헤더 판정이
# 전부 어긋난다. 로컬↔CI 발산이 아니라 **로컬↔로컬 발산**이라 더 안 보인다.
#
# 판정을 정규식이 아니라 substr로 하는 것도 같은 이유다 — 방언·앵커 해석에 기대지 않으면
# 이 부류가 애초에 생기지 않는다. 이걸 잡아낸 것은 아래 대조군(`blocks >= 3`)이다.
TBL="$(awk '
  substr($0, 1, 9) == "packages:" { inpkg = 1; next }
  { if (substr($0, length($0), 1) == "\r") $0 = substr($0, 1, length($0) - 1) }
  inpkg == 0 { next }
  {
    if ($0 == "") next                                  # 빈 줄은 블록 구분자일 뿐
    c1 = substr($0, 1, 1); c2 = substr($0, 2, 1); c3 = substr($0, 3, 1)
    if (c1 != " ") { inpkg = 0; next }                  # 최상위 키 → packages 매핑 종료
    if (c2 != " ") next
    if (c3 == " " || c3 == "#") {                       # 4칸 들여쓰기 본문 · 2칸 주석
      if (substr($0, 1, 10) == "    proxy:" && cur != "") proxy[cur] = 1
      next
    }
    name = substr($0, 3)                                # 2칸 들여쓰기 = 블록 헤더
    sub(/: *$/, "", name); gsub(/'"'"'/, "", name)
    n++; order[n] = name; proxy[name] = 0; cur = name
  }
  END { for (i = 1; i <= n; i++) printf "%d\t%s\t%d\n", i, order[i], proxy[order[i]] }
' "$CFG")"

idx_of()   { printf '%s\n' "$TBL" | awk -F'\t' -v n="$1" '$2 == n { print $1 }'; }
proxy_of() { printf '%s\n' "$TBL" | awk -F'\t' -v n="$1" '$2 == n { print $3 }'; }

# ⚠️ 대조군 — awk가 실제로 블록을 파싱했는지부터 확인한다. `packages:` 키 이름이나 들여쓰기가
# 바뀌면 TBL이 비고, 그러면 아래 어서션이 전부 "빈 값 == 빈 값"으로 조용히 통과할 수 있다.
blocks="$(printf '%s\n' "$TBL" | grep -c . || true)"
assert_ok test "$blocks" -ge 3

own="$SCOPE/*"
assert_ok test -n "$(idx_of "$own")"
assert_eq "0" "$(proxy_of "$own")" \
  "$own 에 proxy가 붙어 있다 — 업스트림에 같은 버전이 있으면 로컬 게시가 E409로 죽는다(harness/install/registries/verdaccio.yaml 게차)"

# 순서: 자기 스코프가 범용 스코프 패턴보다 **앞**이어야 한다(Verdaccio는 첫 매치를 쓴다).
own_i="$(idx_of "$own")"
any_i="$(idx_of '@*/*')"
assert_ok test -n "$any_i"
if [ -n "$own_i" ] && [ -n "$any_i" ]; then
  assert_ok test "$own_i" -lt "$any_i"
fi

# 반대 방향 — 나머지 두 패턴은 uplink에 물려 있어야 한다. 이게 없으면 전이 의존성
# (jose·openid-client·@keycloak/keycloak-admin-client 등)이 해석되지 않는다.
assert_eq "1" "$(proxy_of '@*/*')"  "@*/* 에 proxy가 없다 — 스코프 전이 의존성이 해석되지 않는다"
assert_eq "1" "$(proxy_of '**')"    "** 에 proxy가 없다 — 비스코프 전이 의존성이 해석되지 않는다"

# ---- 소스 **추가** 언어들: 출처를 기록하고 단언하는가 (이슈 #167) ----
#
# node·rust·dotnet은 **구조적 격리**를 쓴다(verdaccio 스코프 uplink 차단 · cargo source
# replacement · nuget packageSourceMapping) — 위 어서션이 node 쪽을 지킨다. 나머지 여섯은
# 공개 레지스트리를 살려둔 채 로컬을 **추가**할 뿐이라, 같은 좌표·같은 버전이 공개에 있으면
# 거기서 받아도 설치가 성공하고 하네스는 초록이 된다. 그 순간 검증 대상은 방금 만든 산출물이
# 아니라 공개 패키지다.
#
# 실측(2026-08-11)이 두 사실을 확정했다:
#   (1) 지금은 여섯 전부 로컬이 이긴다 — pypiserver·mvn-repo·mvn-repo-kotlin·gemserver·
#       satis-web·file GOPROXY가 각각 서빙한 것을 각 패키지 매니저의 기록으로 확인했다.
#   (2) 그러나 그것은 **보장이 아니다** — 로컬 인덱스를 못 쓰는 상태로 같은 pip 명령을 돌리면
#       PyPI에서 받아 `exit 0`으로 끝난다(files.pythonhosted.org URL 실측).
#
# 그래서 각 consume 스크립트는 출처를 파일로 남기고(`provenance.txt`), **로컬이 아니면
# `installed.ok`를 쓰지 않는다**. 이 가드는 그 두 가지가 스크립트에 실재하는지 본다 —
# 격리 설정과 달리 이 단언은 "설정이 이렇다"가 아니라 "실제로 어디서 받았나"를 겨눈다.
CONSUME="$ROOT/harness/install/consume"
prov_langs=0
for L in python java kotlin ruby php go node rust; do
  f="$CONSUME/$L-run.sh"
  assert_ok test -f "$f"
  [ -f "$f" ] || continue
  prov_langs=$((prov_langs + 1))
  body="$(cat "$f")"
  assert_contains "$body" 'provenance.txt' \
    "$L-run.sh 가 SDK 출처를 기록하지 않는다 — 초록/빨강만으로는 로컬을 검증했는지 알 수 없다(#167)"
  # ⚠️ 기록만으로는 부족하다. 기록은 사람이 읽어야 동작하고, 야간 실행의 로그를 매일 읽는
  # 사람은 없다. 판정(`installed.ok`)이 출처에 **의존**해야 한다.
  assert_contains "$body" 'PROVENANCE_OK' \
    "$L-run.sh 가 출처를 단언하지 않는다 — 공개 레지스트리에서 받아도 installed.ok가 써진다(#167)"

  # ⚠️ **문자열 존재만 보는 것으로는 공허하다 — 실측으로 확인했다.** 단언을 `if true; then`으로
  # 바꿔도 위 두 어서션은 통과했다(29 passed). 그래서 두 가지를 더 못박는다:
  #   (a) `PROVENANCE_OK=1`은 **provenance.txt를 읽는 조건** 안에서만 설정돼야 한다
  #   (b) `installed.ok` 쓰기는 `[ "$PROVENANCE_OK" = 1 ]` **뒤에** 와야 한다(판정 의존성)
  #
  # ⚠️ **1라운드(줄-윈도우 휴리스틱)는 PoC 세 개는 막았지만 그 PoC가 대표하는 *부류*는 못 막았다
  # — 외부 검토가 2라운드에서 REAL한 우회 넷을 실측 재현했다(#167 후속4, task-A5-report.md):**
  #   1. **주석이 "then"을 흉내낸다** — else 분기 안에 `# 주석; then`처럼 세미콜론+then으로 끝나는
  #      주석 줄이 있으면, 주석을 벗기지 않은 채 줄 끝만 보는 판정이 그 줄을 진짜 then으로 오인해
  #      진짜 else보다 먼저 멈춘다. `mark_check`도 같은 정규식을 재사용해 같은 방식으로 속는다.
  #   2. **elif를 아예 모른다** — `elif ...; then`도 문자열로는 "; then"으로 끝나 이전 판정이 그걸
  #      주 if의 then으로 착각한다(else만 보고 elif는 안 봤다).
  #   3. **같은 줄 여러 절** — `else PROVENANCE_OK=1; fi`처럼 else와 대입이 한 줄에 있으면, 뒤로
  #      걷는 스캔이 대입 **자기 줄**은 보지 않고 그 앞줄부터 봐서 같은 줄의 else를 놓친다.
  #   4. **빈 홑/겹따옴표만 막았다** — `grep -q '.'`나 `grep -q "[a-z]"`처럼 *비어있지 않지만
  #      의미상 아무거나 매치하는* 패턴은 안 걸린다. "패턴이 있다"가 아니라 "패턴이 실제로 근거
  #      변수를 가리키는가"를 봐야 한다.
  #
  # **2라운드 구조적 재작성** — 8언어 스크립트 전체를 실측해서 얻은 결론: 휴리스틱을 더 추가하는
  # 대신 셸 코드가 실제로 취하는 모양에 맞춰 파싱한다.
  #   (A) 각 줄에서 따옴표 밖 `#`부터는 주석으로 잘라내고(반례1), `;`로 나눈 **절(clause)** 단위로
  #       분석하며(반례3 — `else X; fi`가 절 2개로 갈린다), `if`/`elif`/`else`/`then`/`fi`가 절
  #       **맨 앞 단어**로 붙어 있으면(`then PROVENANCE_OK=1`처럼) 그 키워드만 따로 떼어 별도
  #       절로 만든다. 이 절의 흐름을 뒤로 걸으며 `if`/`fi` 중첩은 depth로 건너뛰고, 같은 깊이에서
  #       `else`나 `elif`를 먼저 만나면(반례2 — elif도 else와 동일 취급) 무조건 거부, `then`을
  #       만나면 그 then을 연 것이 `if`인지 `elif`인지 계속 뒤로 걸어 확인한다.
  #   (B) 근거 grep을 "패턴이 비어있지 않다"가 아니라 "패턴이 이 스크립트가 실제로 유도한
  #       로컬-소스 변수를 가리킨다"로 판정한다(반례4). 8언어를 다시 읽고 실제 조건절에 쓰인
  #       변수만 모았다 — 새 변수를 지어내지 않았다:
  #         `$REG`        — python/php/ruby/node: `REG="${REGISTRY_URL:-...}"`(각 REGISTRY_URL 파생)
  #         `$_kreg`      — kotlin: build.gradle.kts `uri(...)`에서 뽑은 로컬 maven 저장소 URL
  #         `$LOCAL_REG`  — rust: cargo-local-registry 마운트 경로 상수
  #         `${_id}`/`$_id` — java: for 루프 변수(저장소 id 후보, `>${_id}=` 형태로 grep 패턴에 등장)
  #         `$_local_url` — java: 같은 grounding 로직이 유도하는 로컬 URL(방어적으로 포함 — 리뷰 라운드1 지시)
  #       go는 grep을 안 쓰므로 특례로 `GOPROXY=.*go mod download`를 그대로 유지한다.
  #   `gated`가 1·2·3·4를, `mark_check`가 1의 mark_check쪽 절반(주석에 속는 것)과 마커 재배치를
  #   같은 절 엔진으로 닫는다(재현·비공허성 실측: task-A5-report.md 「Fix round 1」).
  ok_line="$(grep -n '^  if \[ "\$PROVENANCE_OK" = 1 \]; then$' "$f" | head -1 | cut -d: -f1)"
  assert_ok test -n "$ok_line"

  combined="$(awk -v ok_line="${ok_line:-0}" -v marker=': > "$STATUS/installed.ok"' '
    function ltrim(s) { gsub(/^[ \t]+/, "", s); return s }
    function rtrim(s) { gsub(/[ \t\r]+$/, "", s); return s }
    function trim(s) { return rtrim(ltrim(s)) }
    function strip_comment(line,    i, c, out, inS, inD) {
      inS = 0; inD = 0; out = ""
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == SQ && !inD) { inS = !inS; out = out c; continue }
        if (c == "\"" && !inS) { inD = !inD; out = out c; continue }
        if (c == "#" && !inS && !inD) break
        out = out c
      }
      return out
    }
    # 따옴표·괄호(=$(...))를 인식하며 top-level ";"로 절을 나눈다 — 반례3(같은 줄 여러 절).
    function split_clauses(line, CL,    i, c, inS, inD, depth, cur, n) {
      inS = 0; inD = 0; depth = 0; cur = ""; n = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == SQ && !inD) { inS = !inS; cur = cur c; continue }
        if (c == "\"" && !inS) { inD = !inD; cur = cur c; continue }
        if (!inS && !inD) {
          if (c == "(") { depth++; cur = cur c; continue }
          if (c == ")") { if (depth > 0) depth--; cur = cur c; continue }
          if (c == ";" && depth == 0) { n++; CL[n] = cur; cur = ""; continue }
        }
        cur = cur c
      }
      if (trim(cur) != "") { n++; CL[n] = cur }
      return n
    }
    # 절 맨 앞의 if/elif/else/then/fi를 자기 절로 떼어낸다 — "then PROVENANCE_OK=1"·
    # "else PROVENANCE_OK=1" 같은 한 줄-여러-키워드를 분리된 절처럼 취급한다(반례2·3).
    function peel(clause, OUT,    t, kw, rest, n) {
      t = trim(clause); n = 0
      while (1) {
        kw = ""
        if (t == "if" || t == "elif" || t == "else" || t == "then" || t == "fi") { kw = t; rest = "" }
        else if (match(t, /^(if|elif|then|else)[ \t]+/)) {
          kw = substr(t, 1, RLENGTH); gsub(/[ \t]+$/, "", kw)
          rest = substr(t, RLENGTH + 1)
        }
        if (kw == "") break
        n++; OUT[n] = kw
        t = trim(rest)
        if (t == "") break
      }
      if (t != "") { n++; OUT[n] = t }
      return n
    }
    # PROVENANCE_OK=1 절(m)에서 뒤로 걸어 이 대입을 감싼 분기를 구조적으로 찾는다.
    # else/elif를 만나면 즉시 거부(반례2) — then을 만나면 그 then을 연 게 if인지 elif인지
    # 계속 확인한다. if로 확인되면 그 if..then 사이(조건절)에 근거가 있는지 본다.
    function analyze(m,    i, t, depth, phase, then_pos, if_pos, verdict, blob, j, seg, v) {
      depth = 0; phase = "seek"; then_pos = 0; if_pos = 0; verdict = "reject"
      for (i = m - 1; i >= 1; i--) {
        t = C[i]
        if (t == "fi") { depth++; continue }
        if (depth > 0) { if (t == "if") depth--; continue }
        if (phase == "seek") {
          if (t == "else") { verdict = "reject"; break }
          if (t == "elif") { verdict = "reject"; break }
          if (t == "then") { phase = "find_opener"; then_pos = i; continue }
          continue
        }
        if (t == "if")   { verdict = "accept"; if_pos = i; break }
        if (t == "elif") { verdict = "reject"; break }
        if (t == "else") { verdict = "reject"; break }
        continue
      }
      if (verdict != "accept") return "reject"
      blob = ""
      for (j = if_pos + 1; j <= then_pos - 1; j++) blob = blob " " C[j]
      if (blob ~ /GOPROXY=.*go mod download/) return "accept"
      # 근거 grep — provenance.txt를 읽는 grep 구간(파이프 앞까지)에 로컬-소스 변수가 있어야 한다.
      if (match(blob, /grep[^|]*provenance\.txt/)) {
        seg = substr(blob, RSTART, RLENGTH)
        for (v = 1; v <= NVARS; v++) if (match(seg, VARPATS[v])) return "accept"
      }
      return "reject"
    }
    BEGIN {
      SQ = sprintf("%c", 39); BS = sprintf("%c", 92)
      nv = 0
      # 로컬-소스 근거 변수 — 8개 언어를 실측해서 얻은 목록(#167 후속4, 지어내지 않음):
      VARPATS[++nv] = BS "$REG([^A-Za-z0-9_]|$)"        # python/php/ruby/node: REGISTRY_URL 파생
      VARPATS[++nv] = BS "$_kreg([^A-Za-z0-9_]|$)"       # kotlin: build.gradle.kts uri()에서 유도
      VARPATS[++nv] = BS "$LOCAL_REG([^A-Za-z0-9_]|$)"   # rust: cargo-local-registry 마운트 경로
      VARPATS[++nv] = BS "$_local_url([^A-Za-z0-9_]|$)"  # java: mirrorOf 예외에서 유도한 로컬 URL(방어적)
      VARPATS[++nv] = BS "$" BS "{?_id" BS "}?([^A-Za-z0-9_]|$)"  # java: for 루프 저장소 id 후보(${_id})
      NVARS = nv
      M = 0
    }
    {
      clean = strip_comment($0)
      if (trim(clean) == "") next
      nc = split_clauses(clean, CL)
      for (k = 1; k <= nc; k++) {
        np = peel(CL[k], PC)
        for (p = 1; p <= np; p++) { M++; C[M] = trim(PC[p]); L[M] = NR }
      }
      delete CL; delete PC
    }
    END {
      total = 0; good = 0
      for (m = 1; m <= M; m++) {
        if (C[m] != "PROVENANCE_OK=1") continue
        total++
        if (analyze(m) == "accept") good++
      }
      print "GATED\t" ((total > 0 && total == good) ? "yes" : ("no(total=" total " good=" good ")"))

      # mark_check — 같은 절 스트림으로 ok_line의 "then"부터 그 then을 닫는 "fi"까지 구간을 잡고,
      # 마커가 파일 전체에서 정확히 1건 + 그 구간 안에 있는지 본다(반례1의 mark_check쪽·마커 재배치).
      m0 = 0
      for (m = 1; m <= M; m++) if (L[m] == ok_line + 0 && C[m] == "then") { m0 = m; break }
      if (m0 == 0) { print "MARK\tno(no-ok-then)"; exit }
      depth = 1; close_m = 0
      for (m = m0 + 1; m <= M; m++) {
        if (C[m] == "if") { depth++; continue }
        if (C[m] == "fi") { depth--; if (depth == 0) { close_m = m; break } }
      }
      if (close_m == 0) { print "MARK\tno(no-close)"; exit }
      cnt = 0; bad = 0
      for (m = 1; m <= M; m++) {
        if (index(C[m], marker) > 0) {
          cnt++
          if (!(m > m0 && m < close_m)) bad = 1
        }
      }
      print "MARK\t" ((cnt == 1 && bad == 0) ? "yes" : ("no(cnt=" cnt " bad=" bad ")"))
    }
  ' "$f")"
  gated="$(printf '%s\n' "$combined" | sed -n 's/^GATED\t//p')"
  mark_check="$(printf '%s\n' "$combined" | sed -n 's/^MARK\t//p')"

  assert_eq "yes" "$gated" \
    "$L-run.sh 의 PROVENANCE_OK=1 대입 중 관측에 근거하지 않은 것이 있다 — else/elif 분기이거나 근거 grep이 로컬-소스 변수를 가리키지 않는데 무조건 통과로 바뀌었나(#167)"
  assert_eq "yes" "$mark_check" \
    "$L-run.sh 의 installed.ok 마커 쓰기가 게이트 하나 안에 정확히 1건이 아니다 — 게이트 뒤로 옮겨졌거나 트레일링 무조건 쓰기가 추가됐을 수 있다(#167)"
done
# ⚠️ 대조군 — 파일명 규칙이 바뀌면 위 루프가 한 번도 돌지 않고 조용히 통과한다.
assert_eq "8" "$prov_langs" "소스-추가 8개 언어의 consume 스크립트를 다 찾지 못했다 — 파일명 규칙이 바뀌었나"

assert_report
