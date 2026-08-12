#!/bin/sh
# 런타임 엔트리포인트(node 참조 구현) — install-net에서 실행된다(docker run --network install-net).
# 1) install: Verdaccio에 게시된 @xzawed/keycloak-sdk@0.1.0을 레지스트리 설치(실제 소비자 명령).
# 2) quickstart 스모크: 설치된 패키지로 실 Keycloak에 대해 quickstart 실행.
# 3) app boot: harness/apps/node/server.js를 설치된 패키지 의존으로 기동.
# 상태는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와 무관하게 오케스트레이터가 읽음).
set -u
STATUS="${STATUS_DIR:-/status}"
REG="${REGISTRY_URL:-http://verdaccio:4873}"
# 릴리스 버전 — 오케스트레이터(install-verify.sh)가 -e PKG_VER로 주입한다. 기본값은 하네스가
# 릴리스 경로 바깥에서 단독 실행될 때(nightly harness 등)의 값이다.
PKG_VER="${PKG_VER:-0.1.0}"
mkdir -p "$STATUS"
rm -f "$STATUS/installed.ok" "$STATUS/quickstart.ok"

echo "[node-run] 1/3 install — npm install @xzawed/keycloak-sdk@$PKG_VER express --registry $REG"
# 실제 소비자 명령 형태(패키지@버전을 커맨드라인에 명시) — SDK를 레지스트리에서 $PKG_VER로 설치.
if npm install "@xzawed/keycloak-sdk@$PKG_VER" express --registry "$REG" >/tmp/install.log 2>&1; then
  echo "[node-run] npm install 성공 — 출처 확인 중"
  # ⚠️ **출처를 기록한다**(이슈 #167). `npm install --json`은 이 npm(10.9.8)에서
  # `added[].resolved`를 채우지 않는다 — 실측: `--json --dry-run`이 사람이 읽는 "add X Y" 로그 +
  # `{added,removed,changed,audited,funding}` 카운트 요약만 낸다(설치할 URL은 안 낸다). 대신 설치
  # **뒤** `npm ls <pkg> --json`이 실제로 받은 tarball URL을 `resolved` 필드로 기계가독 제공한다
  # (실측: `https://registry.npmjs.org/@xzawed/keycloak-sdk/-/keycloak-sdk-0.1.0-rc.2.tgz`) —
  # 로그 스크레이핑이 아니라 npm이 직접 낸 사실이라 이걸 관측 지점으로 쓴다.
  npm ls "@xzawed/keycloak-sdk" --json >/tmp/npm-ls.json 2>/tmp/npm-ls.err || true
  node - <<'JS' >"$STATUS/provenance.txt" 2>/dev/null || true
const fs = require('fs');
try {
  const tree = JSON.parse(fs.readFileSync('/tmp/npm-ls.json', 'utf8'));
  const dep = tree.dependencies && tree.dependencies['@xzawed/keycloak-sdk'];
  if (dep && dep.resolved) console.log(dep.resolved);
} catch (e) {
  // 파싱 실패 — provenance.txt를 빈 채로 남겨 아래 게이트가 실패 판정하게 둔다.
}
JS
  echo "[node-run] SDK 출처: $(cat "$STATUS/provenance.txt" 2>/dev/null)"
  # ⚠️ **출처 단언**(이슈 #167) — 기록만으로는 부족하다. 기록은 사람이 읽어야 동작하고 야간
  # 실행의 로그를 매일 읽는 사람은 없다. 판정(`installed.ok`)이 출처에 의존해야 한다.
  # ⚠️ **전부 로컬이라야 한다**(기록된 줄이 하나라도 로컬이 아니면 실패) + 빈 파일도 실패.
  # 여덟 언어가 같은 규칙을 쓴다 — "하나라도 로컬"은 부분 출처·시도 URL 혼입을 통과시킨다.
  if [ -s "$STATUS/provenance.txt" ] && ! grep -v -F "$REG" "$STATUS/provenance.txt" | grep -q .; then
    PROVENANCE_OK=1
  else
    PROVENANCE_OK=0
  fi
  if [ "$PROVENANCE_OK" = 1 ]; then
    : > "$STATUS/installed.ok"
    echo "[node-run] install OK (로컬 레지스트리에서 받았다)"
  else
    echo "[node-run] install FAILED — SDK를 로컬($REG)이 아닌 곳에서 받았다: $(cat "$STATUS/provenance.txt" 2>/dev/null)"
    cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
    sleep 3600; exit 1
  fi
else
  echo "[node-run] install FAILED"; cat /tmp/install.log
  cp /tmp/install.log "$STATUS/install.log" 2>/dev/null || true
  sleep 3600; exit 1   # 컨테이너를 살려둬 진단 가능하게(오케스트레이터는 마커 부재로 실패 판정)
fi

echo "[node-run] 2/3 quickstart 스모크 — node quickstart.mjs"
if node quickstart.mjs >/tmp/qs.log 2>&1; then
  : > "$STATUS/quickstart.ok"
  echo "[node-run] quickstart OK"
else
  echo "[node-run] quickstart FAILED(비치명 — app boot·conformance는 계속)"; cat /tmp/qs.log
  cp /tmp/qs.log "$STATUS/quickstart.log" 2>/dev/null || true
fi

echo "[node-run] 3/3 app boot — node server.js (APP_PORT=${APP_PORT:-8090})"
exec node server.js
