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
#
# ⚠️ **좁게 쓰면 서식 변경 하나로 워크플로가 조준에서 빠진다**(독립 리뷰 지목, 셋 다 집안 관용이다):
#   · 줄 이음 — `mvn -B -f java/pom.xml \` + `  -Prelease deploy` → 어느 줄도 매치 안 됨
#   · `./mvnw deploy` — `mvn ` 에 앞 경계를 걸면 놓친다
#   · `publishAndReleaseToMavenCentral` — vanniktech 의 다른 태스크이고, **하필 사람 Portal 클릭을
#     없애는 쪽**이다(사람 게이트를 빼는 그 변경이 증명 게이트까지 함께 뺐다)
# 그래서 (a) 줄 이음을 **먼저 잇고** (b) 패턴을 표기 변주에 견디게 쓴다.
PUBLISH_RE='mvnw?[^|]*deploy|publish[A-Za-z]*MavenCentral|publishAllPublications'

# ── 판정 ────────────────────────────────────────────────────────────────────
# 위반을 한 줄에 하나씩 stdout 으로 낸다(빈 출력 = 위반 없음). 「게시 워크플로 0개」도 위반이다.
#
# ⚠️ **주석을 판정에서 뺀다 — 줄 번호는 보존한다.** 실측으로 걸렸다: `release.yml` 머리말의
# 거버넌스 주석이 「실제 배포(mvn ... deploy)는…」이라고 적고 있어, 주석을 세면 **파일 서두가
# 게시 잡으로 잡힌다**(그러면 권한이 없다고 거짓 보고한다). 빈 줄로 치환해 줄 번호는 살린다.
#
# ⚠️ **줄 이음(`\`)을 먼저 잇는다** — 안 이으면 `mvn … \` + `  -Prelease deploy` 가 두 줄로 쪼개져
# 어느 줄도 게시 명령으로 안 보인다. 이은 줄은 **뒤 줄 자리에 남겨** 줄 번호를 보존한다
# (순서 검사가 줄 번호로 판정하기 때문이다).
_nc() {
  sed 's/^[[:space:]]*#.*$//' "$1" | awk '
    {
      cur = $0
      if (carry != "") { cur = carry " " cur; carry = "" }
      # ⚠️ `\r?` 를 쓰지 않는다 — POSIX awk 의 정규식 이스케이프는 구현마다 갈린다.
      # `[[:space:]]` 가 CR 을 포함하므로 CRLF 도 이것으로 덮인다.
      if (cur ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", cur); carry = cur; print ""; next }
      print cur
    }
    END { if (carry != "") print carry }
  '
}

_findings() { # _findings <워크플로 디렉터리>
  wfdir="$1"
  found=0
  # ⚠️ `*.yaml` 도 본다 — 확장자 하나로 새 레인이 조준에서 빠지면 안 된다(공허 하한은 형제
  # 레인이 채워 주므로 그 누락은 조용하다).
  for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
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

    # ⚠️ **무엇을 증명하는지**도 본다. 예전엔 「단계가 있다」만 봐서, `subject-path` 를 지워도
    # (액션이 기본값으로 아무것도 못 찾아 실패하지만 **정적으로는** 통과) 가드가 조용했다.
    # ⚠️ 여기서 멈춘다 — 「글롭이 배포 집합과 정확히 같은가」는 이 가드가 판정하지 못한다
    # (`-bom` 은 jar 가 없고 kotlin 의 `.module` 은 `build/libs` 밖이다 — 등록부 후속 항목).
    printf '%s\n' "$nc" | grep -qE '^[[:space:]]*subject-path:[[:space:]]*\S' ||
      echo "$wf: $ATTEST 단계에 \`subject-path\` 가 없다 — 무엇을 증명하는지가 비어 있다"

    # ⚠️ 권한은 워크플로 어딘가가 아니라 **게시 잡 안**에 있어야 한다 — 다른 잡의 블록에 있으면
    # 파일 전체 grep 은 통과하는데 실제 잡은 권한이 없어 런타임에 터진다. 잡 헤더(공백 2칸 +
    # 이름 + `:`) 사이를 잘라 게시 명령이 있는 블록만 본다.
    # ⚠️ 잡 슬라이스에 셋을 고쳤다(독립 리뷰 지목):
    #   · **후행 주석** — `  release:  # 게시 잡` 은 예전 헤더 정규식(`:` 뒤 즉시 끝)에 안 맞아
    #     그 잡이 통째로 안 보였고, `buf` 가 **앞 잡부터** 시작해 두 잡을 걸쳤다. 형제 잡 하나가
    #     `id-token: write` 를 갖는 순간 그건 **거짓 통과**가 된다.
    #   · **`exit`** — 파일당 **한 잡만** 권한 검사를 받았다. 게시 잡이 둘이면 둘째는 무검사다.
    #   · **`jobs:` 앞** — `on:` 아래의 `  push:` 도 두 칸 들여쓴 키라 잡 헤더로 읽혔다.
    blks="$(printf '%s\n' "$nc" | awk -v re="$PUBLISH_RE" '
      /^jobs:[[:space:]]*$/ { injobs = 1; next }
      !injobs { next }
      /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ {
        if (hit) printf "%s\036", buf      # 레코드 구분자로 잡 블록을 나눈다(끝내지 않는다)
        buf = ""; hit = 0
      }
      { buf = buf $0 "\n"; if ($0 ~ re) hit = 1 }
      END { if (hit) printf "%s\036", buf }
    ')"
    # 게시 명령을 담은 **모든** 잡 블록을 본다.
    nblk=0
    OLDIFS="$IFS"; IFS='
'
    for blk in $(printf '%s' "$blks" | awk 'BEGIN{RS="\036"} NF{gsub(/\n/,"\035"); print}'); do
      nblk=$((nblk + 1))
      b="$(printf '%s' "$blk" | tr '\035' '\n')"
      for perm in 'id-token: write' 'attestations: write'; do
        printf '%s' "$b" | grep -qF "$perm" ||
          echo "$wf: 게시 잡에 \`$perm\` 이 없다 — 증명 단계가 런타임에 실패한다"
      done
      # ⚠️ **증명 단계가 그 잡 **안**에 있어야 한다.** 파일 전체 grep 만 보면, 증명을 게시 잡
      # **뒤의 다른 잡**으로 옮기고 권한을 두고 와도 전부 통과한다 — 그런데 그 잡은 릴리스 때
      # `build/libs` 가 없는 새 트리를 체크아웃하고 죽는다.
      printf '%s' "$b" | grep -qF "$ATTEST" ||
        echo "$wf: 증명 단계가 게시 잡 **밖**에 있다 — 그 잡은 산출물이 없는 트리에서 돈다"
    done
    IFS="$OLDIFS"
    [ "$nblk" -ge 1 ] ||
      echo "$wf: 게시 명령을 담은 잡 블록을 하나도 못 잘랐다 — 잡 슬라이스가 깨졌다"

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
WITH='        with:'
SUBJ='          subject-path: java/*/target/*.jar'

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
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$OKPERM1" "$OKPERM2" "$STEPS" "$PUBSTEP" "$PIN" "$WITH" "$SUBJ"
assert_eq "" "$(_findings "$W")" "[음성대조] 정상 형태는 위반 없음"

# ── 독립 리뷰가 낸 구멍들의 대조군 ─────────────────────────────────────────

# (g) ⚠️ **줄 이음** — 집안 관용대로 `mvn … \` 로 쪼개면 예전 판정은 이 워크플로를 **통째로
# 건너뛰었다**(어느 줄도 게시 명령으로 안 보인다). 그러면 증명 단계를 지워도 초록이다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" \
    '      - run: mvn -B -f java/pom.xml \' '          -Prelease deploy'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 줄 이음으로 쪼갠 게시 명령도 조준에 든다"

# (h) ⚠️ **다른 태스크 이름** — `publishAndReleaseToMavenCentral` 은 vanniktech 의 다른 태스크이고
# 하필 **사람 Portal 클릭을 없애는** 쪽이다. 예전 패턴은 그 이름을 몰라 워크플로가 빠졌다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" '      - run: ./gradlew publishAndReleaseToMavenCentral'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] publishAndReleaseToMavenCentral 도 게시 명령이다"

# (i) ⚠️ `./mvnw` 래퍼도 게시 명령이다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" '      - run: ./mvnw -B -Prelease deploy'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] ./mvnw 래퍼도 조준에 든다"

# (j) ⚠️ **잡 헤더의 후행 주석** — 예전 헤더 정규식은 `:` 뒤 즉시 끝만 인정해, 주석이 붙으면 그
# 잡이 안 보이고 `buf` 가 **앞 잡부터** 시작해 두 잡을 걸쳤다. 형제 잡이 권한을 갖고 있으면
# 그건 **거짓 통과**가 된다 — 그 상황을 그대로 만든다.
_wf "$HEAD1" "$HEAD2" '  other:' "$PERMS" "$OKPERM1" "$OKPERM2" '  publish:  # 게시 잡' \
    "$PERMS" "$RDPERM" "$STEPS" "$PUBSTEP" "$PIN" "$WITH" "$SUBJ"
assert_contains "$(_findings "$W")" "id-token: write" "[음성대조] 헤더에 주석이 붙어도 잡 경계를 옳게 자른다"

# (k) ⚠️ **게시 잡이 둘** — 예전에는 `exit` 때문에 파일당 첫 잡만 권한 검사를 받았다.
_wf "$HEAD1" "$HEAD2" '  pub1:' "$PERMS" "$RDPERM" "$OKPERM1" "$OKPERM2" "$STEPS" "$PUBSTEP" "$PIN" "$WITH" "$SUBJ" \
    '  pub2:' "$PERMS" "$RDPERM" "$STEPS" "$PUBSTEP" "$PIN" "$WITH" "$SUBJ"
assert_contains "$(_findings "$W")" "id-token: write" "[음성대조] 게시 잡이 둘이면 둘 다 검사한다"

# (l) ⚠️ **증명을 게시 잡 밖으로** 옮기고 권한을 두고 오면 — 줄 순서·존재·핀이 전부 통과한다.
# 그런데 그 잡은 릴리스 때 산출물이 없는 새 트리에서 돈다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$PUBSTEP" \
    '  attest:' "$PERMS" "$OKPERM1" "$OKPERM2" "$STEPS" "$PIN" "$WITH" "$SUBJ"
assert_contains "$(_findings "$W")" "잡 **밖**에 있다" "[음성대조] 증명이 게시 잡 밖이면 판정이 운다"

# (m) ⚠️ `subject-path` 가 없으면 무엇을 증명하는지가 비어 있다(다른 것은 전부 정상이다).
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$OKPERM1" "$OKPERM2" "$STEPS" "$PUBSTEP" "$PIN"
assert_contains "$(_findings "$W")" "subject-path" "[음성대조] subject-path 가 없으면 판정이 운다"

# (f) 게시 명령이 하나도 없으면 공허 하한이 운다.
printf '%s\n' 'name: x' 'jobs:' '  a:' '    steps:' '      - run: echo hi' > "$W/x.yml"
assert_contains "$(_findings "$W")" "하나도 못 찾았다" "[음성대조] 게시 워크플로가 0개면 공허 하한이 운다"

assert_report
