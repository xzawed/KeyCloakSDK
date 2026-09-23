#!/usr/bin/env sh
# **게시하는 잡은 게시한 것을 증명한다** — 출처 증명(attestation) 불변식.
#
# 무엇을 지키는가: `published-floor.yml` 은 Central 에서 받은 바이트의 **클래스 버전**을 읽지만,
# 그 바이트가 **우리가 빌드한 것인지**는 못 읽는다. 그 칸을 채우는 것이 릴리스 잡의
# `actions/attest-build-provenance` 다. 그 단계가 조용히 빠지면 — 권한 정리 중에, 잡을 옮기다가,
# 액션 상향을 되돌리다가 — **오라클은 그대로 초록이고 증명만 사라진다.**
#
# ⚠️ **대상을 손으로 적지 않는다.** 「게시하는 잡」은 파생한다 — Central 에 올리는 명령
# (`mvn … deploy` · `publishToMavenCentral`)을 부르는 워크플로가 그것이다. 새 JVM 레인이 생기면
# 자동으로 조준에 들어온다(손목록이면 그때 조용히 빠진다).
#
# ⚠️ **판정을 함수로 뽑은 것은 취향이 아니라 대조군 때문이다** — 같은 `_findings` 를 실제 트리와
# 합성 픽스처에 각각 먹인다. 자기 자신을 다시 부르는 방식은 무한 재귀가 되고, 살아 있는 상태만
# 단언하면 판정 로직을 지워도 초록이 된다(등록부 `selftests-with-no-negative-case`).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$DIR/../.."

ATTEST='actions/attest-build-provenance'
# Central 에 올리는 명령. 새 표기가 생기면 여기 더한다 — 그 diff 자체가 리뷰 대상이다.
PUBLISH_RE='mvn .*deploy|publishToMavenCentral'

# ── 판정 ────────────────────────────────────────────────────────────────────
# 위반을 한 줄에 하나씩 stdout 으로 낸다(빈 출력 = 위반 없음). 「게시 워크플로 0개」도 위반이다.
#
# ⚠️ **주석을 판정에서 뺀다 — 줄 번호는 보존한다.** 실측으로 걸렸다: `release.yml` 머리말의
# 거버넌스 주석이 「실제 배포(mvn ... deploy)는…」이라고 적고 있어, 주석을 세면 **파일 서두가
# 게시 잡으로 잡힌다**(그러면 권한이 없다고 거짓 보고한다). 빈 줄로 치환해 줄 번호는 살린다.
_nc() { sed 's/^[[:space:]]*#.*$//' "$1"; }

_findings() { # _findings <워크플로 디렉터리>
  wfdir="$1"
  found=0
  for f in "$wfdir"/*.yml; do
    [ -f "$f" ] || continue
    nc="$(_nc "$f")"
    printf '%s\n' "$nc" | grep -qE "$PUBLISH_RE" || continue
    found=$((found + 1))
    wf="$(basename "$f")"

    if ! printf '%s\n' "$nc" | grep -qF "$ATTEST"; then
      echo "$wf: Central 에 올리는데 \`$ATTEST\` 단계가 없다 — 게시 바이트의 출처를 아무도 증명하지 않는다"
      continue
    fi
    printf '%s\n' "$nc" | grep -qE "uses:[[:space:]]*$ATTEST@[0-9a-f]{40}" ||
      echo "$wf: $ATTEST 이 40자 SHA 로 핀되지 않았다"

    # ⚠️ 권한은 워크플로 어딘가가 아니라 **게시 잡 안**에 있어야 한다 — 다른 잡의 블록에 있으면
    # 파일 전체 grep 은 통과하는데 실제 잡은 권한이 없어 런타임에 터진다. 잡 헤더(공백 2칸 +
    # 이름 + `:`) 사이를 잘라 게시 명령이 있는 블록만 본다.
    blk="$(printf '%s\n' "$nc" | awk -v re="$PUBLISH_RE" '
      /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { if (hit) { printf "%s", buf; exit } buf = ""; hit = 0 }
      { buf = buf $0 "\n"; if ($0 ~ re) hit = 1 }
      END { if (hit) printf "%s", buf }
    ')"
    for perm in 'id-token: write' 'attestations: write'; do
      printf '%s' "$blk" | grep -qF "$perm" ||
        echo "$wf: 게시 잡에 \`$perm\` 이 없다 — 증명 단계가 런타임에 실패한다"
    done

    # 증명이 게시보다 **뒤**인가. 앞이면 Maven 이 라이프사이클을 다시 돌아 서명한 바이트와
    # 올라간 바이트가 갈릴 수 있다(두 빌드 다 재현 가능하지 않다).
    pl=$(printf '%s\n' "$nc" | grep -nE "$PUBLISH_RE" | tail -1 | cut -d: -f1)
    al=$(printf '%s\n' "$nc" | grep -nF "$ATTEST" | tail -1 | cut -d: -f1)
    [ "$al" -gt "$pl" ] ||
      echo "$wf: 증명(${al}행)이 게시(${pl}행)보다 앞이다 — 서명한 바이트와 올라간 바이트가 갈릴 수 있다"
  done
  # ⚠️ 공허 하한 — 파생이 깨져 0 개를 훑으면 위 루프가 통째로 안 돌고 「위반 없음」이 된다.
  # 개수를 박지 않는다: 규칙은 「게시하는 워크플로가 최소 하나는 있다」이다.
  [ "$found" -ge 1 ] || echo "게시 명령(\`$PUBLISH_RE\`)을 부르는 워크플로를 하나도 못 찾았다 — 파생이 깨졌다"
}

# ── 실제 트리 ───────────────────────────────────────────────────────────────
real="$(_findings "$ROOT/.github/workflows")"
assert_eq "" "$real" "[출처증명] 실제 워크플로에 위반이 있다"

# ── 음성 대조 ───────────────────────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
W="$TMP/wf"; mkdir -p "$W"
PUBSTEP='      - run: mvn -B -f java/pom.xml -Prelease deploy'
PIN="      - uses: $ATTEST@4d101475d8b20a2381f78447822ac1eab6504dd8"

_wf() { printf '%s\n' "$@" > "$W/x.yml"; }
HEAD1='name: x'; HEAD2='jobs:'; HEAD3='  publish:'; PERMS='    permissions:'
OKPERM1='      id-token: write'; OKPERM2='      attestations: write'; RDPERM='      contents: read'
STEPS='    steps:'

# (a) 증명 단계가 아예 없다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$PUBSTEP"
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 증명 단계가 없으면 판정이 운다"

# (b) 단계는 있는데 게시보다 **앞**이다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$OKPERM1" "$OKPERM2" "$STEPS" "$PIN" "$PUBSTEP"
assert_contains "$(_findings "$W")" "보다 앞이다" "[음성대조] 증명이 게시보다 앞이면 판정이 운다"

# (c) 권한이 빠졌다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$PUBSTEP" "$PIN"
assert_contains "$(_findings "$W")" "id-token: write" "[음성대조] 권한이 빠지면 판정이 운다"

# ⚠️ 권한이 **다른 잡**에 있는 경우 — 파일 전체 grep 이면 통과한다. 잡 범위를 자르는 이유다.
_wf "$HEAD1" "$HEAD2" '  other:' "$PERMS" "$OKPERM1" "$OKPERM2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$PUBSTEP" "$PIN"
assert_contains "$(_findings "$W")" "id-token: write" "[음성대조] 권한이 다른 잡에 있으면 판정이 운다"

# (d) SHA 핀이 아니라 태그 ref.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$OKPERM1" "$OKPERM2" "$STEPS" "$PUBSTEP" "      - uses: $ATTEST@v4"
assert_contains "$(_findings "$W")" "SHA 로 핀되지" "[음성대조] 태그 ref 면 판정이 운다"

# (e) 정상 형태는 **아무 위반도 내지 않는다** — 이것이 없으면 위 넷이 「항상 운다」와 구분되지 않는다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$OKPERM1" "$OKPERM2" "$STEPS" "$PUBSTEP" "$PIN"
assert_eq "" "$(_findings "$W")" "[음성대조] 정상 형태는 위반 없음"

# (f) 게시 명령이 하나도 없으면 공허 하한이 운다.
printf '%s\n' 'name: x' 'jobs:' '  a:' '    steps:' '      - run: echo hi' > "$W/x.yml"
assert_contains "$(_findings "$W")" "하나도 못 찾았다" "[음성대조] 게시 워크플로가 0개면 공허 하한이 운다"

assert_report
