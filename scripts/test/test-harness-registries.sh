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
for L in python java kotlin ruby php go; do
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
  # 이래도 의미론까지 증명하지는 못한다(그건 컨테이너를 띄워야 한다) — 그러나 "고치는 것처럼
  # 보이는 편집"으로 단언이 무력화되는 경로는 닫힌다.
  gated="$(awk '
    /PROVENANCE_OK=1/ { for (i = NR - 4; i < NR; i++) if (i > 0 && buf[i] ~ /grep .*provenance\.txt/) { print "yes"; exit } }
    { buf[NR] = $0 }
  ' "$f")"
  assert_eq "yes" "$gated" \
    "$L-run.sh 의 PROVENANCE_OK=1 이 provenance.txt를 읽는 조건 안에 있지 않다 — 무조건 통과로 바뀌었나(#167)"

  ok_line="$(grep -n '\[ "\$PROVENANCE_OK" = 1 \]' "$f" | head -1 | cut -d: -f1)"
  mark_line="$(grep -n ': > "\$STATUS/installed.ok"' "$f" | head -1 | cut -d: -f1)"
  assert_ok test -n "$ok_line"
  assert_ok test -n "$mark_line"
  if [ -n "$ok_line" ] && [ -n "$mark_line" ]; then
    assert_ok test "$mark_line" -gt "$ok_line"
  fi
done
# ⚠️ 대조군 — 파일명 규칙이 바뀌면 위 루프가 한 번도 돌지 않고 조용히 통과한다.
assert_eq "6" "$prov_langs" "소스-추가 6개 언어의 consume 스크립트를 다 찾지 못했다 — 파일명 규칙이 바뀌었나"

assert_report
