#!/usr/bin/env sh
# 하네스 Docker 빌드는 상류의 일시 장애를 재시도한다 — `harness/lib/build-retry.sh` 와 그것을 거치는 빌드 자리 전부.
#
# ⚠️ **실측이 이 가드를 만들었다**(등록부 harness-nightly-upstream-transients). 야간 harness 가 Docker 빌드 안에서 상류
# fetch 가 일시로 실패해 빨개지고, 코드가 그대로인 채 다음 밤 저절로 닫혔다(score-all · `harness/verify.sh` 스텝):
#   run 42441515425(2026-11-08) php 앱 이미지 — composer `… zipball/… file could not be downloaded (HTTP/2 504)`
#   run 44979301872(2026-11-22) java 앱 이미지 — `Non-resolvable import POM … junit-bom:pom:6.1.3 (absent)`(아티팩트는 있다)
#                               kotlin 앱 이미지 — `could not resolve plugin artifact 'com.vanniktech.maven.publish…:0.37.0'`
# 그때 하네스의 빌드 자리 16 곳 어디에도 재시도가 없었다.
#
# 세 절 — `# >>> hbr:<이름>` · `# <<< hbr:<이름>` 표지로 감싼다(변이 3요건 (c) 가 절 단위로 끈다 — 절은 서로 기대지 않는다):
#   static  하네스 셸 스크립트의 빌드(`docker build` · `docker compose … build` · `… --build`)는 전부 헬퍼를 거친다.
#   helper  최대 3 회 · 시도 사이 ${HARNESS_BUILD_RETRY_DELAY:-60} 초 · 마지막 시도의 종료코드 그대로 · 재시도마다 경고
#           주석 하나와 retries 파일 한 줄 · 첫 시도 성공은 아무것도 안 쓴다.
#   sites   빌드 자리 전부 — 세 번 실패하면 그 자리의 기존 실패 처리가 돈다. 갈라 놓은 자리(build → up)는 빌드만
#           재시도하고 기동은 한 번이다.
# 가짜 docker · sleep · curl 을 PATH 앞에 둔다 — 진짜 Docker 는 건드리지 않고, 대상 스크립트는 임시 거울 트리에서 돈다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"

_t="$(mktemp -d)"
trap 'rm -rf "$_t"' EXIT

# hbr_scan <파일…> — 빌드 호출마다 「RAW|WRAPPED<TAB>파일:줄<TAB>원문 첫 줄」 한 줄.
# 줄마다 주석을 걷고 문자열 속(로그 문구)을 가린 뒤(`"$( … )"` 안은 코드로 둔다) `\` 줄잇기를 붙이고, `docker build` ·
# `docker compose … build` · `docker compose … --build` 를 찾는다. 그 호출을 담은 단순 명령의 첫 낱말이
# `build_with_retry` 면 WRAPPED, 아니면 RAW 다(`timeout 900 docker build` 같은 다른 감싸개도 RAW).
# ⚠️ 못 보는 것: 홑따옴표 안 스크립트(`bash -c 'docker build …'`) · eval 문자열 · `$DOCKER build` · `docker image build` ·
#   `docker-compose`(v1). 히어독 본문은 코드로 읽는다(RAW 로 운다 — 시끄러운 쪽이다). 하네스가 빌드를 쓰는 모양은 아니다.
hbr_scan() {
  awk -v sq="'" '
    function mask(s,    o, i, n, c, d, st) {
      o = ""; d = 0; st[0] = "T"; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st[d] == "S") { if (c == sq) { d--; o = o c } else o = o "_"; continue }
        if (st[d] == "D") {
          if (c == "\\") { o = o "__"; i++ }
          else if (c == "\"") { d--; o = o c }
          else if (c == "$" && substr(s, i + 1, 1) == "(") { st[++d] = "C"; o = o "$("; i++ }
          else o = o "_"
          continue
        }
        if (c == "\\") { o = o substr(s, i, 2); i++; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;]/)) break
        if (c == "\"") st[++d] = "D"
        else if (c == sq) st[++d] = "S"
        else if (c == "(" && d > 0) st[++d] = "C"
        else if (c == ")" && d > 0) d--
        o = o c
      }
      return o
    }
    function scan(L, where, orig,    q, r, p, b, cls) {
      q = 0
      while ((r = index(substr(L, q + 1), "docker")) > 0) {
        p = q + r; q = p + 5
        if (p > 1 && substr(L, p - 1, 1) ~ /[A-Za-z0-9_.\/-]/) continue
        if (substr(L, p) !~ /^docker[ \t]+(build|compose[^|;&)]*([ \t]build|--build))/) continue
        b = substr(L, 1, p - 1)
        while (gsub(/\([^()]*\)/, "_", b) > 0) { }
        sub(/.*[;&|()`]/, "", b)
        while (sub(/^[ \t]*(if|then|else|elif|do|while|until|time|!)([ \t]|$)/, "", b) > 0) { }
        cls = (b ~ /^[ \t]*build_with_retry[ \t]/) ? "WRAPPED" : "RAW"
        print cls "\t" where "\t" orig
      }
    }
    FNR == 1 { cont = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      m = mask(line)
      if (cont) buf = buf " " m
      else { buf = m; at = FNR; first = line }
      if (buf ~ /\\$/) { sub(/\\$/, "", buf); cont = 1; next }
      cont = 0
      scan(buf, FILENAME ":" at, first)
    }
  ' "$@"
}
# 추적되는 하네스 셸 스크립트 전부를 훑는다. ⚠️ 목록이 비면 awk 가 stdin 을 읽어 멈추므로 부르지 않는다(공허는 하한이 잡는다).
_hfiles="$(cd "$ROOT" && git ls-files -- 'harness/*.sh' 2>/dev/null || true)"
hbr_scan_tree() { if [ -n "$_hfiles" ]; then (cd "$ROOT" && hbr_scan $_hfiles); fi; }

# ── 가짜 셋 ──────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$_t/bin"
cat > "$_t/bin/docker" <<'EOF'
#!/usr/bin/env sh
# 가짜 docker — 호출을 한 줄씩 적는다. 겨눈 대상(HBR_TARGET 과 같은 낱말)의 빌드(`build` · `--build`)는 HBR_EXITS 의
# 종료코드를 차례로 내고(목록이 다하면 마지막 값), 그 대상의 기동(`up`)은 HBR_UP_EXIT 를 낸다. 나머지는 성공이다.
printf '%s\n' "$*" >> "$HBR_LOG"
_b=1; _h=1; _u=1; _st=''; _p=''
for _a in "$@"; do
  case "$_a" in build|--build) _b=0 ;; up) _u=0 ;; esac
  [ "$_a" = "$HBR_TARGET" ] && _h=0
  if [ "$_p" = -v ]; then case "$_a" in *:/status) _st="${_a%:/status}" ;; esac; fi
  _p="$_a"
done
if [ "$_h" = 0 ] && [ "$_b" = 0 ]; then
  _n=$(( $(cat "$HBR_COUNT" 2>/dev/null || echo 0) + 1 ))
  echo "$_n" > "$HBR_COUNT"
  exit "$(echo "$HBR_EXITS" | awk -v n="$_n" '{ print (n <= NF) ? $n : $NF }')"
fi
if [ "$_h" = 0 ] && [ "$_u" = 0 ]; then exit "${HBR_UP_EXIT:-0}"; fi
# 소비자 컨테이너가 남기는 표지 — dotnet 의 둘째 빌드(net10.0)는 첫 소비자의 표지 뒤에서만 닿는다.
if [ -n "$_st" ]; then : > "$_st/installed.ok"; : > "$_st/asset.ok"; : > "$_st/quickstart.ok"; : > "$_st/done"; fi
[ "${1:-}" = inspect ] && echo healthy
exit 0
EOF
cat > "$_t/bin/sleep" <<'EOF'
#!/usr/bin/env sh
# 가짜 sleep — 잔 초를 적고 바로 돌아온다(헬퍼가 지연 변수를 읽는지 이것으로 잰다).
printf '%s\n' "$*" >> "$HBR_SLEEPS"
EOF
printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$_t/bin/curl"
chmod +x "$_t/bin/docker" "$_t/bin/sleep" "$_t/bin/curl"

# docker 호출 기록에서 센다 — $1=기록 $2=대상 낱말.
hbr_builds() { awk -v t="$2" '{ b = h = 0; for (i = 1; i <= NF; i++) { if ($i == "build" || $i == "--build") b = 1; if ($i == t) h = 1 } if (b && h) n++ } END { print n + 0 }' "$1"; }
hbr_ups() { awk -v t="$2" '{ u = b = h = 0; for (i = 1; i <= NF; i++) { if ($i == "up") u = 1; if ($i == "--build") b = 1; if ($i == t) h = 1 } if (u && h && !b) n++ } END { print n + 0 }' "$1"; }
hbr_upbuilds() { awk -v t="$2" '{ u = b = h = 0; for (i = 1; i <= NF; i++) { if ($i == "up") u = 1; if ($i == "--build") b = 1; if ($i == t) h = 1 } if (u && h && b) n++ } END { print n + 0 }' "$1"; }
hbr_warns() { grep -cF -- "::warning title=harness build retry::$2 attempt " "$1" || true; }
hbr_count() { if [ -f "$1" ]; then grep -cF -- "$2" "$1" || true; else echo 0; fi; }
hbr_exists() { if [ -e "$1" ]; then echo 있음; else echo 없음; fi; }

# ── 거울 · 실행 ──────────────────────────────────────────────────────────────────────────────────
# hbr_mirror stub|real — 새 거울 트리 $_t/m/harness. 대상 스크립트를 같은 상대 배치로 복사한다(진짜 트리에는 아무것도
# 쓰지 않는다). stub 이면 publish/*.sh 를 성공만 하는 대역으로 바꾼다 — install-verify 의 빌드 자리까지 곧장 가게.
hbr_mirror() {
  rm -rf "$_t/m"
  _hm="$_t/m/harness"
  mkdir -p "$_hm/lib" "$_hm/install/lib" "$_hm/install/publish/out/rust-local-registry"
  cp "$ROOT/harness/verify.sh" "$ROOT/harness/run.sh" "$_hm/"
  cp "$ROOT/harness/install/install-verify.sh" "$ROOT/harness/install/lib.sh" "$_hm/install/"
  cp "$ROOT/harness/install/lib/verify-lib.sh" "$_hm/install/lib/"
  cp "$ROOT/harness/install/publish/"*.sh "$_hm/install/publish/"
  # 헬퍼가 없는 트리(변경 전)에서도 시험은 끝까지 돌아 빨개져야 한다 — 복사 실패로 멈추지 않는다.
  cp "$ROOT/harness/lib/build-retry.sh" "$_hm/lib/" 2>/dev/null || true
  if [ "$1" = stub ]; then
    for _hp in "$_hm/install/publish/"*.sh; do printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$_hp"; done
  fi
}
# hbr_run <대상> <빌드 종료코드 열> <기동 종료코드> <명령…> — 거울의 harness/ 에서 가짜를 앞세워 돌린다.
# 결과: $_t/r.rc · r.out(stdout+stderr) · r.log(docker 호출) · r.sleeps
hbr_run() {
  _hr_t="$1"; _hr_x="$2"; _hr_u="$3"; shift 3
  : > "$_t/r.log"; : > "$_t/r.sleeps"; rm -f "$_t/r.n"
  _hr_rc=0
  (
    cd "$_t/m/harness"
    HBR_TARGET="$_hr_t" HBR_EXITS="$_hr_x" HBR_UP_EXIT="$_hr_u" HBR_LOG="$_t/r.log" HBR_COUNT="$_t/r.n" \
    HBR_SLEEPS="$_t/r.sleeps" HARNESS_BUILD_RETRY_DELAY=0 SKIP_KEYCLOAK=1 PATH="$_t/bin:$PATH" \
      "$@" < /dev/null > "$_t/r.out" 2>&1
  ) || _hr_rc=$?
  echo "$_hr_rc" > "$_t/r.rc"
}
# hbr_evidence <증거 파일(-=출력)> <글자(비면 파일이 있기만 하면 된다)> → 있음|없음
hbr_evidence() {
  if [ "$1" = - ]; then _he="$_t/r.out"; else _he="$_t/m/harness/$1"; fi
  if [ ! -f "$_he" ]; then echo 없음; return 0; fi
  if [ -z "$2" ] || grep -qF -- "$2" "$_he"; then echo 있음; else echo 없음; fi
}

# >>> hbr:static
_scan="$(hbr_scan_tree)"
_raw="$(printf '%s\n' "$_scan" | awk -F'\t' '$1 == "RAW" { print "  " $2 ": " $3 }')"
assert_eq "" "$_raw" "[정적] 하네스 셸 스크립트가 헬퍼(build_with_retry) 밖에서 빌드한다 — 상류 일시 장애 한 번에 야간이 빨개진다:
$_raw"
_nw="$(printf '%s\n' "$_scan" | grep -c '^WRAPPED' || true)"
# 공허 하한 — 스캔이 깨지면 「빌드가 없어서」 초록이 된다. ⚠️ 세어서 박는다: 실측 16(2026-11-24 — install-verify 11 ·
# publish node · ruby · rust 각 1 · run 1 · verify 1).
assert_eq "ok" "$(ok_if "$([ "$_nw" -ge 16 ] && echo 0 || echo 1)" "$_nw")" \
  "[정적] 헬퍼를 거치는 빌드 자리를 16 개 미만 찾았다($_nw) — 스캔이 깨졌나?"
# 대조군 — 스캐너가 무엇을 RAW 로 보고 무엇을 안 보는가. 본체와 **같은 함수**를 부른다(사본을 검사하면 본체가 썩어도 초록이다).
cat > "$_t/fx.sh" <<'EOF'
docker build -t raw .
  log "SDK 빌드 실패(docker build --target sdk)"
# docker build -t commented .
if ! build_with_retry ok "$f" docker build -t ok .; then
timeout 900 docker build -t other-wrapper .
docker compose -f c.yml \
  up -d --build svc
docker compose --profile apps up -d "app-$L"
build_with_retry ok "$f" true; docker compose build svc
id="$(docker build -q .)"
id="$(build_with_retry ok "$f" docker build -q .)"
echo build_with_retry docker build
x="$(hostpath "a")"; build_with_retry ok "$(hostpath "$f")" docker build .
EOF
_fxo="$(hbr_scan "$_t/fx.sh" | awk -F'\t' '{ n = split($2, a, ":"); printf "%s%s:%s", (NR > 1 ? " " : ""), $1, a[n] }')"
assert_eq "RAW:1 WRAPPED:4 RAW:5 RAW:6 RAW:9 RAW:10 WRAPPED:11 RAW:12 WRAPPED:13" "$_fxo" \
  "[정적·대조군] 스캐너가 픽스처를 다르게 가른다(줄:판정) — 로그 문구 · 주석은 빌드가 아니고, 다른 감싸개 · 줄잇기 · 명령 치환 속 빌드는 RAW 다"
# <<< hbr:static

# >>> hbr:helper
HBR_LIB="$ROOT/harness/lib/build-retry.sh"
# hbr_helper <빌드 종료코드 열> <지연(비우면 변수 없음)> — 헬퍼를 직접 부른다. 결과: $_t/h.rc · h.out · h.log · h.sleeps · h.retries
hbr_helper() {
  : > "$_t/h.log"; : > "$_t/h.sleeps"; rm -f "$_t/h.n" "$_t/h.retries"
  _hh_rc=0
  (
    if [ -n "$2" ]; then HARNESS_BUILD_RETRY_DELAY="$2"; export HARNESS_BUILD_RETRY_DELAY; else unset HARNESS_BUILD_RETRY_DELAY; fi
    HBR_TARGET=hbr-probe HBR_EXITS="$1" HBR_LOG="$_t/h.log" HBR_COUNT="$_t/h.n" HBR_SLEEPS="$_t/h.sleeps" PATH="$_t/bin:$PATH" \
      bash -c '. "$1" && build_with_retry hbr-probe "$2" docker build -t hbr-probe .' hbr "$HBR_LIB" "$_t/h.retries" \
      < /dev/null > "$_t/h.out" 2>&1
  ) || _hh_rc=$?
  echo "$_hh_rc" > "$_t/h.rc"
}

# (a) 첫 시도에 성공 — 한 번 부르고 아무것도 안 쓴다.
hbr_helper 0 7
assert_eq "0" "$(cat "$_t/h.rc")" "[헬퍼] (a) 첫 시도 성공의 종료코드가 0 이 아니다: $(cat "$_t/h.out")"
assert_eq "1" "$(hbr_builds "$_t/h.log" hbr-probe)" "[헬퍼] (a) 첫 시도에 성공했는데 빌드를 다시 불렀다"
assert_eq "0" "$(hbr_warns "$_t/h.out" hbr-probe)" "[헬퍼] (a) 첫 시도 성공에 경고 주석을 냈다"
assert_eq "없음" "$(hbr_exists "$_t/h.retries")" "[헬퍼] (a) 첫 시도 성공에 retries 파일을 만들었다 — 「재시도 없음」이 빈 파일로 남는다"
assert_eq "" "$(cat "$_t/h.sleeps")" "[헬퍼] (a) 첫 시도 성공에 잤다"

# (b) 한 번 실패 뒤 성공 — 두 번 부르고, 경고 하나 · 한 줄 · 지연 변수가 없으면 기본 60 초를 한 번.
hbr_helper '1 0' ''
assert_eq "0" "$(cat "$_t/h.rc")" "[헬퍼] (b) 재시도 끝에 성공했는데 종료코드가 0 이 아니다: $(cat "$_t/h.out")"
assert_eq "2" "$(hbr_builds "$_t/h.log" hbr-probe)" "[헬퍼] (b) 한 번 실패 뒤 다시 시도하지 않았다(또는 성공 뒤에도 불렀다)"
assert_eq "1" "$(hbr_warns "$_t/h.out" hbr-probe)" "[헬퍼] (b) 재시도 한 번에 경고 주석이 하나가 아니다"
assert_contains "$(cat "$_t/h.out")" "::warning title=harness build retry::hbr-probe attempt 1 failed (exit 1) — retrying" \
  "[헬퍼] (b) 경고 주석의 모양이 다르다"
assert_eq "1" "$(hbr_count "$_t/h.retries" "hbr-probe attempt 1 failed (exit 1) — retrying")" \
  "[헬퍼] (b) 재시도가 retries 파일에 그 한 줄로 남지 않았다"
assert_eq "1" "$(hbr_count "$_t/h.retries" " attempt ")" "[헬퍼] (b) 재시도 한 번에 retries 줄이 하나가 아니다"
assert_eq "60" "$(cat "$_t/h.sleeps")" "[헬퍼] (b) 지연 변수가 없으면 시도 사이에 60 초를 한 번 자야 한다"

# (c) 세 번 실패(exit 17) — 세 번 부르고 17 을 그대로 돌려준다. 재시도는 둘이다(경고 둘 · 두 줄 · 지연 둘).
hbr_helper 17 7
assert_eq "17" "$(cat "$_t/h.rc")" "[헬퍼] (c) 세 번 실패의 종료코드를 그대로 돌려주지 않는다 — 실패가 성공으로 삼켜지면 야간이 빈 이미지로 간다"
assert_eq "3" "$(hbr_builds "$_t/h.log" hbr-probe)" "[헬퍼] (c) 실패하는 빌드를 세 번 시도하지 않았다"
assert_eq "2" "$(hbr_warns "$_t/h.out" hbr-probe)" "[헬퍼] (c) 재시도 두 번에 경고 주석이 둘이 아니다(마지막 실패는 재시도가 아니다)"
assert_eq "2" "$(hbr_count "$_t/h.retries" " attempt ")" "[헬퍼] (c) 재시도 두 번에 retries 줄이 둘이 아니다"
assert_eq "7
7" "$(cat "$_t/h.sleeps")" "[헬퍼] (c) 시도 사이에 HARNESS_BUILD_RETRY_DELAY(7) 초를 두 번 자야 한다 — 지연 변수를 안 읽나?"

# (d) 돌려주는 것은 **마지막** 시도의 코드다 — 첫 실패의 코드가 아니다. retries 줄은 UTC 시각으로 시작한다(로컬 재실행이 쌓여도 가른다).
hbr_helper '17 18 19' 0
assert_eq "19" "$(cat "$_t/h.rc")" "[헬퍼] (d) 마지막 시도의 종료코드(19)를 돌려주지 않는다"
assert_eq "2" "$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z hbr-probe attempt [12] failed \(exit 1[78]\) ' "$_t/h.retries" 2>/dev/null || true)" \
  "[헬퍼] (d) retries 줄이 「UTC 시각 · 라벨 · 시도 · 종료코드」 모양이 아니다"
# <<< hbr:helper

# >>> hbr:sites
# 빌드 자리 표 — 자리마다 한 줄:
#   스크립트(harness/ 기준)|인자|대상(빌드하는 이미지 · 서비스 = 헬퍼 라벨)|증거 파일(harness/ 기준, -=출력)|증거 글자(비면 있기만)|종료코드(비면 안 본다)|갈랐나
# 증거 = 그 자리의 **기존 실패 처리**가 돌았다는 흔적(fail_lang 의 error · capture_compose_ps · error.json · log + exit 1).
# ⚠️ 아래에서 정적 스캔과 파일마다 자리 수를 대조한다 — 헬퍼를 거치는 새 자리는 여기 행이 생겨야 지나간다.
HBR_SITES="$(cat <<'EOF'
install/install-verify.sh|go|install-consume-go|install/report/signals/go.install.json|consume/go.Dockerfile 빌드 실패||
install/install-verify.sh|dotnet|install-consume-dotnet|install/report/signals/dotnet.install.json|consume/dotnet.Dockerfile 빌드 실패||
install/install-verify.sh|dotnet|install-consume-dotnet10|install/report/signals/dotnet.install.json|consume/dotnet10.Dockerfile 빌드 실패||
install/install-verify.sh|node|install-consume-node|install/report/signals/node.install.json|consume/node.Dockerfile 빌드 실패||
install/install-verify.sh|python|install-consume-python|install/report/signals/python.install.json|consume/python.Dockerfile 빌드 실패||
install/install-verify.sh|java|install-consume-java|install/report/signals/java.install.json|consume/java.Dockerfile 빌드 실패||
install/install-verify.sh|php|install-consume-php|install/report/signals/php.install.json|consume/php.Dockerfile 빌드 실패||
install/install-verify.sh|rust|install-consume-rust|install/report/signals/rust.install.json|consume/rust.Dockerfile 빌드 실패||
install/install-verify.sh|ruby|gemserver|install/report/signals/ruby.install.json|gemserver 기동(docker compose up) 실패||split
install/install-verify.sh|ruby|install-consume-ruby|install/report/signals/ruby.install.json|consume/ruby.Dockerfile 빌드 실패||
install/install-verify.sh|kotlin|install-consume-kotlin|install/report/signals/kotlin.install.json|consume/kotlin.Dockerfile 빌드 실패||
install/publish/node.sh||install-node-sdk-builder|-|SDK 빌드 실패(docker build --target sdk)|1|
install/publish/ruby.sh||install-ruby-gem-tool|-|도구 이미지 빌드 실패(docker build)|1|
install/publish/rust.sh||install-rust-sdk-builder|-|빌드 실패(docker build) — publish/rust.Dockerfile 로그 참고|1|
run.sh|go|app-go|report/signals/go.compose-ps.txt|||split
verify.sh|go|app-go|report/signals/go.error.json|build/up failed||split
EOF
)"

# retries 파일은 gitignore 안이다 — 로컬 실행마다 워킹트리가 더러워지지 않게(업로드되는 신호 디렉터리 둘).
for _ig in harness/report/signals/build-retries.txt harness/install/report/signals/build-retries.txt; do
  assert_eq "ok" "$(git -C "$ROOT" check-ignore -q "$_ig" && echo ok || echo 'gitignore 밖')" \
    "[자리] $_ig 가 gitignore 밖이다 — 로컬 실행마다 워킹트리가 더러워진다"
done

_ns=0
while IFS='|' read -r _f _a _tg _ev _et _erc _split; do
  [ -n "$_f" ] || continue
  _ns=$((_ns + 1))
  # ⚠️ 절대 경로로 부른다 — install-verify.sh 는 자기 디렉터리로 cd 한 **뒤** `dirname "${BASH_SOURCE[0]}"` 로
  # lib/verify-lib.sh 를 찾아, 상대 경로로 부르면 그 소싱이 깨진다(CI 는 `cd harness/install && ./install-verify.sh`).
  case "$_f" in
    install/install-verify.sh) set -- bash "$_t/m/harness/$_f" --version 0.1.0 "$_a" ;;
    *) if [ -n "$_a" ]; then set -- bash "$_t/m/harness/$_f" "$_a"; else set -- bash "$_t/m/harness/$_f"; fi ;;
  esac
  case "$_f" in
    install/*) _rf="$_t/m/harness/install/report/signals/build-retries.txt" ;;
    *) _rf="$_t/m/harness/report/signals/build-retries.txt" ;;
  esac
  case "$_f" in install/publish/*) _mode=real ;; *) _mode=stub ;; esac

  # (c) 세 번 실패(exit 17) — 세 번 시도 · 경고 둘 · 두 줄 · 기동 없음 · 그 자리의 기존 실패 처리가 돈다.
  hbr_mirror "$_mode"
  hbr_run "$_tg" 17 0 "$@"
  _w="[자리 (c)] $_f($_tg)"
  assert_eq "3" "$(hbr_builds "$_t/r.log" "$_tg")" "$_w — 세 번 실패하는 빌드를 세 번 시도하지 않았다"
  assert_eq "0" "$(hbr_ups "$_t/r.log" "$_tg")" "$_w — 빌드가 실패했는데 기동을 시도했다"
  assert_eq "2" "$(hbr_warns "$_t/r.out" "$_tg")" "$_w — 재시도 두 번에 경고 주석이 둘이 아니다"
  assert_eq "2" "$(hbr_count "$_rf" "$_tg attempt ")" "$_w — 재시도 두 번이 업로드되는 신호 디렉터리에 두 줄로 남지 않았다"
  assert_eq "있음" "$(hbr_evidence "$_ev" "$_et")" "$_w — 세 번 실패 뒤 그 자리의 실패 처리가 돌지 않았다($_ev: $_et)"
  [ -z "$_erc" ] || assert_eq "$_erc" "$(cat "$_t/r.rc")" "$_w — 세 번 실패 뒤 종료코드가 그 자리 실패 처리의 것이 아니다"

  # 갈라 놓은 자리(build → up) — 빌드만 재시도하고 기동은 한 번, `--build` 없이. (a) 첫 시도 성공 · (b) 한 번 실패 뒤
  # 성공 · (u) 빌드 성공 뒤 기동 실패(기동은 재시도하지 않고 그 자리의 실패 처리가 돈다).
  if [ "$_split" = split ]; then
    for _sc in a b u; do
      case "$_sc" in
        a) _sx=0; _su=0; _eb=1; _ew=0; _eev=없음 ;;
        b) _sx='1 0'; _su=0; _eb=2; _ew=1; _eev=없음 ;;
        u) _sx=0; _su=1; _eb=1; _ew=0; _eev=있음 ;;
      esac
      hbr_mirror "$_mode"
      hbr_run "$_tg" "$_sx" "$_su" "$@"
      _w="[자리 갈림 ($_sc)] $_f($_tg)"
      assert_eq "$_eb" "$(hbr_builds "$_t/r.log" "$_tg")" "$_w — 빌드 시도 수가 다르다"
      assert_eq "1" "$(hbr_ups "$_t/r.log" "$_tg")" "$_w — 기동을 정확히 한 번(--build 없이) 하지 않았다 — 기동은 재시도하지 않는다"
      assert_eq "0" "$(hbr_upbuilds "$_t/r.log" "$_tg")" "$_w — 기동이 --build 를 달고 있다 — 재시도 밖에서 다시 빌드한다"
      assert_eq "$_ew" "$(hbr_warns "$_t/r.out" "$_tg")" "$_w — 경고 주석 수가 다르다"
      assert_eq "$_ew" "$(hbr_count "$_rf" "$_tg attempt ")" "$_w — retries 줄 수가 다르다"
      if [ "$_ew" = 0 ]; then assert_eq "없음" "$(hbr_exists "$_rf")" "$_w — 재시도가 없었는데 retries 파일을 만들었다"; fi
      assert_eq "$_eev" "$(hbr_evidence "$_ev" "$_et")" "$_w — 그 자리의 실패 처리가 돌았는가가 다르다(기대: $_eev)"
    done
  fi
done <<EOF
$HBR_SITES
EOF

# 표 ↔ 정적 스캔 — 파일마다 자리 수가 같아야 한다(헬퍼를 거치는 새 자리는 위 표에 행이 있어야 지나간다).
_tab="$(printf '%s\n' "$HBR_SITES" | awk -F'|' 'NF > 1 { n["harness/" $1]++ } END { for (f in n) print f, n[f] }' | sort)"
_scn="$(hbr_scan_tree | awk -F'\t''$1 == "WRAPPED" { split($2, a, ":"); n[a[1]]++ } END { for (f in n) print f, n[f] }' | sort)"
assert_eq "$_tab" "$_scn" "[자리] 행동 표와 정적 스캔의 파일별 자리 수가 다르다 — 헬퍼를 거치는 자리마다 위 표에 행을 두라"
# 공허 하한 — 표가 깨져 루프가 안 돌면 초록이 된다. ⚠️ 세어서 박는다: 실측 16(2026-11-24).
assert_eq "ok" "$(ok_if "$([ "$_ns" -ge 16 ] && echo 0 || echo 1)" "$_ns")" "[자리] 돈 빌드 자리가 16 개 미만이다($_ns) — 표가 깨졌나?"
# <<< hbr:sites

assert_report
