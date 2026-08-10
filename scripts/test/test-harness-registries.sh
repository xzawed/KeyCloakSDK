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

assert_report
