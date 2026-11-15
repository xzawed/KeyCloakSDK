#!/usr/bin/env sh
# **게시하는 잡은 게시한 것을 증명한다** — 출처 증명(attestation) 불변식.
#
# 무엇을 지키는가: 게시한 바이트가 **우리가 빌드한 것인지**를 증명하는 것은 릴리스 잡의
# `actions/attest-build-provenance` 다(Central · NuGet · crates.io · RubyGems · Packagist 미러). 그 단계가 조용히
# 빠지면 — 권한 정리 중에, 잡을 옮기다가, 액션 상향을 되돌리다가 — 그 판은 증명 없이 나간다. `published-floor.yml`
# 의 `--attest` 는 그것을(JVM 만) **게시된 뒤에야** 본다. 이 시험은 태그 전에 막는다.
# npm · PyPI 는 레지스트리가 증명을 단다(`npm publish --provenance` · pypa 액션의 PEP 740) — 그 스위치와 서명 권한을
# 본다(`_native_findings`). Go 는 게시 명령이 없다 — proxy 가 태그를 가져가고 체크섬 DB 가 모두에게 같은 바이트를
# 보장한다(`_unclassified` 의 면제 하나).
#
# ⚠️ **대상을 손으로 적지 않는다.** 「게시하는 잡」은 파생한다 — 레지스트리에 올리는 명령
# (`mvn … deploy` · `publishToMavenCentral` · `dotnet nuget push` · `cargo publish` · `gem push` · 미러 태그 push)을
# 부르는 워크플로가 그것이다. 그리고 그 파생이 놓치는 레인이 없도록 **태그로 트리거되는 워크플로는 전부**
# 셋 중 하나로 분류돼야 한다(`_unclassified`) — 게시 명령의 표기가 바뀌어(`gem push` → `rake release`) 조준에서
# 빠지면 조용하지 않고 운다.
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
# ⚠️ 미러 태그 push 는 `<브랜치>:refs/tags/…` 꼴만이다 — `dispatch-release.yml` 이 이 저장소에 태그를 미는
# `git push <url> "refs/tags/<tag>"` 는 게시가 아니다(콜론이 없다 — 대조군이 고정한다).
PUBLISH_RE='mvnw?[^|]*deploy|publish[A-Za-z]*MavenCentral|publishAllPublications|dotnet nuget push|cargo publish|gem push|git push[^|]*[^[:space:]"'"'"']:refs/tags/'

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
    # ⚠️ **올리지 않는 deploy 는 게시 명령이 아니다 — 아래가 전부 참일 때 그 줄만.** central-publishing 0.12.0+ 의
    # `skipUpload` 는 「Nothing is sent to Central」이다(ci.yml release-bundle 이 이 자리다).
    #   (A) 그 줄의 `skipUpload=` 가 전부 `-DskipUpload=true` 뒤 공백·줄끝이고 `&&`·`||`·`;` 가 없다 — 둘째 명령을
    #       붙이면 그 명령까지 지워지고, `true''x` 는 셸이 붙여 Maven 에 `truex` 로 간다
    #   (B) 파일 전체의 `skipUpload=` 도 전부 그 꼴이다 — YAML 접기(`run: >`)로 다음 줄에 `-DskipUpload=false` 를
    #       붙이면 줄 판정은 못 본다
    #   (C) 파일에 자격증명이 들어올 통로가 글자로 없다 — `secrets`·`inputs.`·`vars.`·`id-token`(대소문자 무시).
    #       (A)(B)만이면 0.12.0 아래로 내린 플러그인이나 POM 의 `<skipUpload>false` 가 그 플래그를 무시하고 올린다.
    # 그 줄은 빈 줄로 바꿔 줄 번호를 지킨다 — 같은 워크플로의 다른 deploy 줄은 그대로 조준에 남는다.
    skip_all_true="$(printf '%s\n' "$nc" | awk '
      { t = $0 " "; a = $0
        if (gsub(/skipUpload=/, "&", a) != gsub(/-DskipUpload=true[[:space:]]/, "&", t)) bad = 1 }
      END { print bad ? "no" : "yes" }')"
    if [ "$skip_all_true" = yes ] && ! printf '%s\n' "$nc" | grep -qiE 'secrets|inputs\.|vars\.|id-token'; then
      nc="$(printf '%s\n' "$nc" | awk '
        /mvnw?[^|]*deploy/ && !/&&|\|\||;/ {
          t = $0 " "; a = $0
          n_true = gsub(/-DskipUpload=true[[:space:]]/, "&", t)
          n_all = gsub(/skipUpload=/, "&", a)
          if (n_all >= 1 && n_all == n_true) { print ""; next }
        }
        { print }
      ')"
    fi
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

# ── 레지스트리가 증명을 다는 레인(npm · PyPI) ─────────────────────────────────
# npm 은 `--provenance`, PyPI 는 pypa 액션의 `attestations`(기본 켜짐)로 레지스트리가 증명을 단다. 둘 다 그 잡의
# `id-token: write` 로 서명한다. 셋 중 하나만 빠져도 증명 없이 나가고 게시는 초록이다 — 그 셋을 본다.
NPM_RE='(^|[^[:alnum:]_-])npm publish'
PYPI_RE='uses:[[:space:]]*pypa/gh-action-pypi-publish@'
# 그 정규식을 담은 잡 블록 가운데 `id-token: write` 가 없는 수(잡 슬라이스는 `_findings` 와 같다 — 권한이 다른 잡에
# 있으면 안 된다).
_blocks_without_idtoken() { # <주석 걷은 본문> <정규식>
  printf '%s\n' "$1" | awk -v re="$2" '
    /^jobs:[[:space:]]*$/ { injobs = 1; next }
    !injobs { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/ { if (hit && !tok) n++; hit = 0; tok = 0 }
    { if ($0 ~ re) hit = 1; if ($0 ~ /id-token:[[:space:]]*write/) tok = 1 }
    END { if (hit && !tok) n++; print n + 0 }
  '
}
_native_findings() { # _native_findings <워크플로 디렉터리>
  wfdir="$1"; n_npm=0; n_pypi=0
  for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
    [ -f "$f" ] || continue
    nc="$(_nc "$f")"; wf="$(basename "$f")"
    pubs="$(printf '%s\n' "$nc" | grep -E "$NPM_RE" || true)"
    if [ -n "$pubs" ]; then
      n_npm=$((n_npm + 1))
      # 플래그 그 자체여야 한다 — `--provenance=false` 는 아니다.
      if printf '%s\n' "$pubs" | grep -vqE -- '--provenance([[:space:]]|$)'; then echo "$wf: \`npm publish\` 에 \`--provenance\` 가 없다 — npm 이 출처 증명 없이 게시한다"; fi
      [ "$(_blocks_without_idtoken "$nc" "$NPM_RE")" = 0 ] || echo "$wf: \`npm publish\` 잡에 \`id-token: write\` 가 없다 — 증명을 서명할 수 없다"
    fi
    if printf '%s\n' "$nc" | grep -qE "$PYPI_RE"; then
      n_pypi=$((n_pypi + 1))
      if printf '%s\n' "$nc" | grep -qiE "^[[:space:]]*attestations:[[:space:]]*[\"']?false"; then echo "$wf: pypa 게시 액션의 \`attestations\` 를 껐다 — PyPI 가 PEP 740 증명 없이 게시한다"; fi
      [ "$(_blocks_without_idtoken "$nc" "$PYPI_RE")" = 0 ] || echo "$wf: pypa 게시 잡에 \`id-token: write\` 가 없다 — 증명을 서명할 수 없다"
    fi
  done
  [ "$n_npm" -ge 1 ] || echo "\`npm publish\` 를 부르는 워크플로를 하나도 못 찾았다 — 파생이 깨졌다"
  [ "$n_pypi" -ge 1 ] || echo "pypa 게시 액션을 쓰는 워크플로를 하나도 못 찾았다 — 파생이 깨졌다"
}

# ── 분류 — 태그로 트리거되는 워크플로는 전부 셋 중 하나다 ─────────────────────────
# (1) 게시 명령(PUBLISH_RE — 위 `_findings` 가 증명을 본다) (2) 레지스트리 증명(npm · PyPI — `_native_findings`) (3) 면제.
# 어디에도 없으면 그 레인은 게시 명령의 표기가 바뀌어 조준에서 빠진 것이다 — 그때 조용하지 않게 운다.
# 면제는 이유와 함께 이름으로만 둔다 — go: 게시 명령이 없다. 태그를 proxy.golang.org 가 가져가고 sum.golang.org
# 체크섬 DB 가 모두에게 같은 바이트를 준다(빌드 산출물이 없다).
EXEMPT_UNPUBLISHED='go-release.yml'
_unclassified() { # _unclassified <워크플로 디렉터리>
  wfdir="$1"; n=0
  for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
    [ -f "$f" ] || continue
    nc="$(_nc "$f")"; wf="$(basename "$f")"
    printf '%s\n' "$nc" | grep -qE '^[[:space:]]+tags:' || continue
    n=$((n + 1))
    if printf '%s\n' "$nc" | grep -qE "$PUBLISH_RE|$NPM_RE|$PYPI_RE"; then continue; fi
    case " $EXEMPT_UNPUBLISHED " in *" $wf "*) continue ;; esac
    echo "$wf: 태그로 트리거되는데 게시 명령을 알아보지 못했다 — 출처 증명 조준에서 빠진다(PUBLISH_RE · npm · PyPI · 면제 어디에도 없다)"
  done
  [ "$n" -ge 1 ] || echo "태그로 트리거되는 워크플로를 하나도 못 찾았다 — 파생이 깨졌다"
}

# ── 실제 트리 ───────────────────────────────────────────────────────────────
real="$(_findings "$ROOT/.github/workflows")"
assert_eq "" "$real" "[출처증명] 실제 워크플로에 위반이 있다"
assert_eq "" "$(_native_findings "$ROOT/.github/workflows")" "[출처증명] npm · PyPI 의 증명 스위치나 서명 권한에 위반이 있다"
assert_eq "" "$(_unclassified "$ROOT/.github/workflows")" "[출처증명] 태그로 게시하는데 분류되지 않은 워크플로가 있다 — 패턴이 그 레인의 게시 명령을 못 알아본다"

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

# (n) 올리지 않는 deploy(ci.yml release-bundle 의 모양) — 시크릿 없는 워크플로의 `-DskipUpload=true` 는
# 게시 명령이 아니다. 이 디렉터리의 유일한 워크플로라 남는 것은 공허 하한 하나여야 한다.
SKIPSTEP='      - run: mvn -B -f java/pom.xml -Prelease deploy -DskipUpload=true -DskipTests'
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$SKIPSTEP"
assert_not_contains "$(_findings "$W")" "단계가 없다" "[대조] 시크릿 없는 워크플로의 -DskipUpload=true deploy 는 게시가 아니다"
assert_contains "$(_findings "$W")" "하나도 못 찾았다" "[대조] 그 워크플로는 게시 워크플로로 세지 않는다"
# (o) 같은 줄이라도 워크플로에 시크릿이 있으면 게시로 본다(플러그인이 플래그를 모르는 판이면 올린다)
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$SKIPSTEP" '        env: { PW: "${{ secrets.CENTRAL_TOKEN_PW }}" }'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 시크릿이 있으면 -DskipUpload=true 도 게시로 본다"
# (p) skipUpload 를 다시 false 로 덮으면 게시다
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" '      - run: mvn -Prelease deploy -DskipUpload=true -DskipUpload=false'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] skipUpload=false 가 함께 있으면 게시로 본다"
# (q) 같은 잡의 다른 deploy 줄은 예외를 받지 않는다
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$SKIPSTEP" "$PUBSTEP"
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 예외는 그 줄만 — 옆의 진짜 deploy 는 조준에 남는다"
# (r) 접두만 같은 값(`-DskipUpload=trueish`)은 true 가 아니다
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" '      - run: mvn -Prelease deploy -DskipUpload=trueish'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] -DskipUpload=trueish 는 예외가 아니다"
# (s) 적대 레그(Grok)가 짚은 우회 — 각각 예외를 받지 않아야 한다
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" '      - run: mvn -Prelease deploy -DskipUpload=true && mvn -Prelease deploy'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 같은 줄의 && 둘째 deploy 는 예외가 아니다"
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" '      - run: mvn -Prelease deploy -DskipUpload=true; mvn -Prelease deploy'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 같은 줄의 ; 둘째 deploy 는 예외가 아니다"
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" '      - run: >' '          mvn -Prelease deploy -DskipUpload=true' '          -DskipUpload=false'
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] YAML 접기로 다음 줄에 -DskipUpload=false 를 붙이면 예외가 아니다"
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "      - run: mvn -Prelease deploy -DskipUpload=true''x"
assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 셸이 이어붙인 true''x 는 예외가 아니다"
for chan in '        with: { token: "${{ inputs.token }}" }' '        env: { U: "${{ vars.CENTRAL_USER }}" }' '      id-token: write' '        env: { P: "${{ Secrets.CENTRAL_TOKEN_PW }}" }'; do
  _wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$SKIPSTEP" "$chan"
  assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 자격증명 통로($chan)가 있으면 예외가 아니다"
done

# (f) 게시 명령이 하나도 없으면 공허 하한이 운다.
printf '%s\n' 'name: x' 'jobs:' '  a:' '    steps:' '      - run: echo hi' > "$W/x.yml"
assert_contains "$(_findings "$W")" "하나도 못 찾았다" "[음성대조] 게시 워크플로가 0개면 공허 하한이 운다"

# ── 네 레인(.NET · Rust · Ruby · PHP 미러)의 게시 명령도 조준에 든다(release-provenance-four-lanes) ──
for cmd in '      - run: dotnet nuget push "artifacts/*.nupkg" --api-key "$K" --source https://api.nuget.org/v3/index.json' \
  '      - run: cargo publish --locked --token "$T"' \
  '      - run: gem push keycloak-sdk-*.gem' \
  '      - run: git push "$REMOTE" "php-split:refs/tags/v${VERSION}"'; do
  _wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" "$cmd"
  assert_contains "$(_findings "$W")" "단계가 없다" "[음성대조] 게시 명령으로 본다 — $cmd"
  _wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$OKPERM1" "$OKPERM2" "$STEPS" "$cmd" "$PIN" "$WITH" "$SUBJ"
  assert_eq "" "$(_findings "$W")" "[대조] 증명이 뒤에 있으면 위반 없음 — $cmd"
done
# 이 저장소에 태그를 미는 push(dispatch-release 의 꼴)는 게시가 아니다 — 콜론 없는 ref 다.
_wf "$HEAD1" "$HEAD2" "$HEAD3" "$PERMS" "$RDPERM" "$STEPS" '      - run: git push "https://github.com/${GITHUB_REPOSITORY}.git" "refs/tags/${TAG}"'
assert_not_contains "$(_findings "$W")" "단계가 없다" "[대조] 이 저장소의 태그 push 는 게시가 아니다"

# ── npm · PyPI — 레지스트리 증명의 스위치와 서명 권한 ─────────────────────────────────
N="$TMP/native"; mkdir -p "$N"
_native_ok() {
  rm -f "$N"/*.yml
  printf '%s\n' 'name: n' 'on:' '  push:' "    tags: ['node-v*']" 'jobs:' '  release:' '    permissions:' '      contents: read' \
    '      id-token: write' '    steps:' '      - run: npm publish --provenance --access public' > "$N/node.yml"
  printf '%s\n' 'name: p' 'on:' '  push:' "    tags: ['py-v*']" 'jobs:' '  release:' '    permissions:' '      id-token: write' \
    '    steps:' '      - uses: pypa/gh-action-pypi-publish@dc37677b2e1c63e2034f94d8a5b11f265b73ba33' '        with:' \
    '          packages-dir: python/dist' > "$N/py.yml"
}
_native_ok
assert_eq "" "$(_native_findings "$N")" "[대조] 정상 npm · PyPI 는 위반 없음"
for mut in 's/ --provenance//' 's/--provenance/--provenance=false/'; do
  _native_ok; sed -i "$mut" "$N/node.yml"
  assert_contains "$(_native_findings "$N")" "\`npm publish\` 에 \`--provenance\` 가 없다" "[음성대조] npm 증명 플래그를 빼면 운다 — $mut"
done
_native_ok; sed -i '/id-token: write/d' "$N/node.yml"
assert_contains "$(_native_findings "$N")" "\`npm publish\` 잡에 \`id-token: write\` 가 없다" "[음성대조] npm 잡에 서명 권한이 없으면 운다"
_native_ok
printf '%s\n' 'name: n' 'jobs:' '  other:' '    permissions:' '      id-token: write' '  release:' '    permissions:' '      contents: read' \
  '    steps:' '      - run: npm publish --provenance' > "$N/node.yml"
assert_contains "$(_native_findings "$N")" "\`npm publish\` 잡에 \`id-token: write\` 가 없다" "[음성대조] 서명 권한이 다른 잡에 있으면 운다"
for off in '          attestations: false' "          attestations: 'false'"; do
  _native_ok; printf '%s\n' "$off" >> "$N/py.yml"
  assert_contains "$(_native_findings "$N")" "\`attestations\` 를 껐다" "[음성대조] PyPI 증명을 끄면 운다 — $off"
done
_native_ok; sed -i '/id-token: write/d' "$N/py.yml"
assert_contains "$(_native_findings "$N")" "pypa 게시 잡에 \`id-token: write\` 가 없다" "[음성대조] PyPI 잡에 서명 권한이 없으면 운다"
rm -f "$N"/*.yml
assert_contains "$(_native_findings "$N")" "\`npm publish\` 를 부르는 워크플로를 하나도 못 찾았다" "[음성대조] npm 레인이 0 이면 공허 하한이 운다"
assert_contains "$(_native_findings "$N")" "pypa 게시 액션을 쓰는 워크플로를 하나도 못 찾았다" "[음성대조] PyPI 레인이 0 이면 공허 하한이 운다"

# ── 분류 — 게시 명령의 표기가 바뀌어 조준에서 빠진 레인은 운다 ─────────────────────────
U="$TMP/uncl"; mkdir -p "$U"
printf '%s\n' 'name: r' 'on:' '  push:' "    tags: ['ruby-v*']" 'jobs:' '  release:' '    steps:' '      - run: bundle exec rake release' > "$U/ruby-release.yml"
assert_contains "$(_unclassified "$U")" "ruby-release.yml: 태그로 트리거되는데 게시 명령을 알아보지 못했다" "[음성대조] 표기가 바뀐 게시(rake release)는 분류 밖이라 운다"
rm -f "$U"/*.yml
printf '%s\n' 'name: g' 'on:' '  push:' "    tags: ['go/v*']" 'jobs:' '  release:' '    steps:' '      - run: echo tagged' > "$U/go-release.yml"
assert_eq "" "$(_unclassified "$U")" "[대조] go 는 면제(체크섬 DB) — 게시 명령이 없어도 분류된다"
mv "$U/go-release.yml" "$U/go2-release.yml"
assert_contains "$(_unclassified "$U")" "go2-release.yml: 태그로 트리거되는데" "[음성대조] 면제는 그 이름뿐 — 다른 파일은 분류 밖"
for f in "$ROOT"/.github/workflows/*-release.yml "$ROOT/.github/workflows/release.yml"; do cp "$f" "$U/"; done
rm -f "$U/go2-release.yml"
assert_eq "" "$(_unclassified "$U")" "[대조] 실제 릴리스 워크플로 아홉은 전부 분류된다"
rm -f "$U"/*.yml
printf '%s\n' 'name: c' 'on: [pull_request]' 'jobs:' '  a:' '    steps:' '      - run: echo' > "$U/ci.yml"
assert_contains "$(_unclassified "$U")" "하나도 못 찾았다" "[음성대조] 태그 트리거 워크플로가 0 이면 공허 하한이 운다"

assert_report
