#!/bin/sh
# 런타임 엔트리포인트(ruby 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 1) install: 정적 gem repo(gemserver)에 게시된 keycloak-sdk@0.1.0을 레지스트리 설치(실제 소비자 명령).
#    --source는 APPEND(치환 아님)이므로 keycloak-sdk 자체는 gemserver에서, faraday/jwt/rack-oauth2
#    등 전이 의존성은 기본 소스인 rubygems.org에서 직접 해석된다(부록 게차 그대로).
# 2) quickstart 스모크: 설치된 gem으로 실 Keycloak에 대해 quickstart.rb 실행.
# 3) app boot: harness/apps/ruby/app.rb를 설치된 gem 의존으로 기동(Sinatra 내장 서버 — puma 사용).
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
STATUS="${STATUS_DIR:-/status}"
REG="${REGISTRY_URL:-http://gemserver:8808}"
# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다(기본값은 단독 실행용).
PKG_VER="${PKG_VER:-0.1.0}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

echo "[ruby-run] 1/3 install — gem install keycloak-sdk --version $PKG_VER --source $REG (+ sinatra/puma/rackup)"
# keycloak-sdk와 sinatra/puma/rackup은 별도 `gem install` 호출로 나눈다: `--version`은 한 커맨드에
# 여러 gem명을 함께 주면 전부에 동일 버전 제약이 걸려버려(sinatra/puma/rackup엔 그 버전이 존재하지
# 않는다) 뒤엣것들이 실패한다 — node의 `npm install pkg@ver express`처럼 한 줄로 합칠 수 없다.
# ⚠️ `-V`는 **출처를 기록하기 위한 것**이다(이슈 #167). `--source`는 APPEND라 rubygems.org가 살아
# 있고, 같은 좌표·같은 버전이 거기에도 있으면 거기서 받아도 초록이다 — 그 순간 검증 대상은 방금
# 만든 산출물이 아니라 공개 gem이다. RubyGems에는 설치 후 출처를 남기는 파일이 없어(설치된 spec은
# source를 기록하지 않는다) 상세 로그가 유일한 관측 지점이다.
# ⚠️ **`--clear-sources`가 필수다 — 실측으로 드러났다.** `--source`만 쓰면 rubygems.org가 그대로
# 남고, 같은 좌표·같은 버전이 공개에도 있으면 RubyGems가 **공개에서 본문을 받는다**. 실측 로그:
#     http://gemserver:8808/info/keycloak-sdk                        ← 로컬: 인덱스
#     http://gemserver:8808/quick/Marshal.4.8/…gemspec.rz            ← 로컬: 스펙
#     https://index.rubygems.org/gems/keycloak-sdk-0.1.0.rc1.gem     ← 공개: **본문**
# 즉 이 레그는 방금 만든 .gem이 아니라 게시된 gem을 검증하고 있었다(#167이 예측한 바로 그 상태).
# 그래서 SDK 자기 좌표만 로컬 소스로 **격리**한다(dotnet packageSourceMapping·rust source
# replacement와 같은 형태). 전이 의존성은 아래 2단계에서 공개 소스로 받는다 —
# `--ignore-dependencies`로 1단계를 SDK 본문에만 한정하고, 2단계 `--conservative`가 이미 설치된
# SDK는 건드리지 않고 빠진 의존성만 채운다.
# ⚠️ **`--clear-sources`는 `--source`보다 먼저 와야 한다** — 순서가 바뀌면 방금 추가한 소스까지
# 지워지고 RubyGems가 기본 소스(rubygems.org)로 되돌아간다. 실측으로 걸렀다: 뒤에 두었더니
# provenance가 전부 `https://index.rubygems.org/...`로 나왔다.
# 2단계: SDK의 **런타임 의존성만** 공개 소스에서 채운다.
# ⚠️ 처음에는 `gem install keycloak-sdk --conservative`로 "빠진 의존성만 채워진다"고 적었는데
# **그것은 아무것도 설치하지 않는다**(`--conservative` = 이미 요구를 만족하는 gem은 건드리지 않음 —
# keycloak-sdk가 이미 설치돼 있으므로 즉시 no-op다). 그 결과 설치는 초록인데 앱이
# `Could not find 'faraday' (~> 2.0) (Gem::MissingSpecError)`로 못 떴다(실측).
# 그렇다고 `--conservative`를 떼면 keycloak-sdk 자체를 **공개에서 다시 받아** 로컬 gem을 덮어쓴다.
# 그래서 의존성 이름을 **설치된 gemspec에서 읽어** 그것만 설치한다 — 하드코딩이 아니라 파생이고,
# 이 단계는 keycloak-sdk를 절대 다시 해석하지 않는다.
install_sdk_deps() {
  ruby -e 'require "rubygems"; Gem::Specification.find_by_name("keycloak-sdk").runtime_dependencies.each { |d| puts "#{d.name}|#{d.requirement}" }' >/tmp/sdk-deps.txt 2>>/tmp/install.log || return 1
  [ -s /tmp/sdk-deps.txt ] || { echo "[ruby-run] SDK 런타임 의존성 목록이 비었다 — gemspec 읽기 실패" >>/tmp/install.log; return 1; }
  _deps_rc=0
  while IFS='|' read -r _dn _dr; do
    [ -n "$_dn" ] || continue
    gem install "$_dn" -v "$_dr" --no-document >>/tmp/install.log 2>&1 || _deps_rc=1
  done </tmp/sdk-deps.txt
  return "$_deps_rc"
}

if gem install keycloak-sdk --version "$PKG_VER" --clear-sources --source "$REG" \
        --ignore-dependencies --no-document -V >/tmp/install.log 2>&1 \
   && install_sdk_deps \
   && gem install sinatra puma rackup --no-document >>/tmp/install.log 2>&1; then
  echo "[ruby-run] gem install 성공 — 출처 확인 중"
  # .gem을 실제로 내려받은 URL. 없으면 "못 찾았다"고 적는다 — 빈 파일은 "공개에서 받았다"와
  # 구분되지 않으므로 침묵시키지 않는다.
  # ⚠️ 예전 구현은 `\.gem`에 매치되는 **첫 줄 하나만** 남겼는데, 그 첫 줄은 실제로 gem 본문이 아니라
  # quick 스펙 URL(`/quick/Marshal.4.8/…gemspec.rz`)이 `\.gem`까지만 잘린 것이었다(실측:
  # `http://gemserver:8808/quick/Marshal.4.8/keycloak-sdk-0.1.0.rc1.gem` — 본문은
  # `/gems/keycloak-sdk-0.1.0.rc1.gem`에 있다). 메타데이터만 로컬이고 본문은 공개에서 받는 조합을
  # 구분하지 못하므로, **이 gem과 관련된 URL을 전부** 남기고 아래에서 전부 로컬인지 본다.
  grep -oE 'https?://[^ "]*keycloak-sdk[^ "]*' /tmp/install.log | sort -u >"$STATUS/provenance.txt" 2>/dev/null || true
  [ -s "$STATUS/provenance.txt" ] || echo "<-V 출력에서 keycloak-sdk URL을 찾지 못했다>" >"$STATUS/provenance.txt"
  echo "[ruby-run] SDK 출처: $(tr '\n' ' ' <"$STATUS/provenance.txt" 2>/dev/null)"
  # ⚠️ **출처 단언**(이슈 #167) — `--source`는 APPEND라 rubygems.org가 살아 있다. 같은 좌표·같은
  # 버전이 거기에도 있으면 거기서 받아도 초록이므로, 판정을 출처에 의존시킨다.
  # ⚠️ **전부 로컬** + **양성 조건**: 로컬에서 `.gem` **본문**(`/gems/…gem`)을 받은 줄이 있어야 한다.
  # 스펙(`/quick/…gemspec.rz`)·인덱스(`/info/…`)만 로컬이고 본문은 공개인 조합이 실제로 있었다.
  if [ -s "$STATUS/provenance.txt" ] && ! grep -v -F "$REG" "$STATUS/provenance.txt" | grep -q . \
     && grep -q "^${REG}.*/gems/.*\.gem$" "$STATUS/provenance.txt"; then
    PROVENANCE_OK=1
  else
    PROVENANCE_OK=0
  fi
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[ruby-run] install OK (로컬 레지스트리에서 받았다)"
  else
    echo "[ruby-run] install FAILED — SDK를 로컬($REG)이 아닌 곳에서 받았거나 URL 기록이 없다: $(tr '\n' ' ' <"$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
else
  echo "[ruby-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[ruby-run] 2/3 quickstart 스모크 — ruby quickstart.rb"
# quickstart.rb는 KC_URL(KC_SERVER_URL이 아님)을 읽는다 — app.rb(KC_SERVER_URL)와 이름이 다르므로
# 이 호출에서만 로컬로 매핑한다(오케스트레이터가 컨테이너에 두 이름을 모두 주입할 필요가 없도록).
if KC_URL="${KC_SERVER_URL:-http://keycloak:8080}" ruby quickstart.rb >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[ruby-run] quickstart OK"
else
  echo "[ruby-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[ruby-run] 3/3 app boot — ruby app.rb (APP_PORT=${APP_PORT:-8090})"
# ⚠️ Sinatra 4/rack-protection 4는 :development 환경(ENV에 APP_ENV/RACK_ENV가 없을 때의 기본값)에서만
# Rack::Protection::HostAuthorization의 permitted_hosts를 채운다(localhost/.localhost/.test + IP
# 와일드카드) — install-net에서 도커 DNS 별칭(예: install-app-ruby)으로 들어오는 요청은 그 목록에 없어
# 전부 403 "Host not permitted"로 막힌다(conformance/security가 정확히 이 경로로 접근 — 실측 확인됨).
# app.rb는 무변경 재사용 대상이라 소스에서 permitted_hosts를 코드로 넓힐 수 없다 — 대신 RACK_ENV를
# production으로 두면 host_authorization 기본값이 빈 해시({})가 되어 검사 자체가 꺼진다(rack-protection
# 소스의 `return true if @all_permitted_hosts.empty?`). app.rb는 :bind/:port를 이미 명시 설정해 두므로
# production 전환이 바인딩 동작에 영향을 주지 않는다.
export RACK_ENV=production
exec ruby app.rb
