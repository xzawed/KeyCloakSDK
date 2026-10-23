#!/usr/bin/env sh
# Central 번들 배치 가드(`scripts/check-central-bundle.mjs`)의 자가테스트.
#
# 이 가드가 채우는 칸: Central Portal 은 번들 배치를 **업로드 뒤에야** 검증한다. 저장소의 어떤 가드도
# 번들을 만들지 않아서 v1.2.0·v1.2.1 이 태그를 자른 뒤에야 「Bundle has content that does NOT have a
# .pom file」로 거부됐다(러너 Maven 3.10.0 + central-publishing 0.11.x 가 넣은 로컬 저장소 장부).
#
# ⚠️ 네트워크도 빌드도 쓰지 않는다 — 번들 목록(`unzip -Z1` 출력)과 픽스처 pom 트리만 쓴다. 실제
# 번들은 `ci.yml` 의 release-bundle 잡이 만든다.
#
# ⚠️ 무게는 「통과한다」가 아니라 **(1) 1.2.0·1.2.1 이 낸 모양을 잡는가 (2) 0 개를 훑고 통과하지
# 않는가 (3) 기대 집합을 손으로 박지 않았는가(pom 에서 파생)**에 있다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-central-bundle.mjs"
REPO="$(cd "$DIR/../.." && pwd)"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
G="io/github/xzawed"

# ── 픽스처 저장소: 부모 + bom(pom 만) + core(jar) + examples(excludeArtifacts 로 게시 밖) ─────────
# 모듈 디렉터리 이름을 artifactId 와 **다르게** 둔다 — 가드가 디렉터리가 아니라 pom 의 artifactId 를
# 읽는지(그리고 자식 pom 의 첫 artifactId 인 `<parent>` 를 건너뛰는지)를 함께 잰다.
R="$FIX/repo"
mkdir -p "$R/java/bom-dir" "$R/java/core-dir" "$R/java/examples-dir"
cat > "$R/java/pom.xml" <<'EOF'
<project>
  <!-- <artifactId>commented-out-id</artifactId> -->
  <groupId>io.github.xzawed</groupId>
  <artifactId>kc-parent</artifactId>
  <modules>
    <module>bom-dir</module>
    <module>core-dir</module>
    <module>examples-dir</module>
  </modules>
  <build><plugins><plugin><configuration>
    <excludeArtifacts><excludeArtifact>kc-examples</excludeArtifact></excludeArtifacts>
  </configuration></plugin></plugins></build>
</project>
EOF
for m in bom:kc-bom core:kc-core examples:kc-examples; do
  d="${m%%:*}-dir"; id="${m#*:}"
  printf '<project>\n  <parent><groupId>io.github.xzawed</groupId><artifactId>kc-parent</artifactId></parent>\n  <artifactId>%s</artifactId>\n</project>\n' "$id" > "$R/java/$d/pom.xml"
done

sums() { for s in md5 sha1 sha256 sha512; do echo "$1.$s"; done; }
pom_only() { # <artifactId> <version>
  f="$G/$1/$2/$1-$2.pom"; echo "$f"; echo "$f.asc"; sums "$f"
}
jar_comp() { # <artifactId> <version>
  pom_only "$1" "$2"
  for c in "" -sources -javadoc; do f="$G/$1/$2/$1-$2$c.jar"; echo "$f"; echo "$f.asc"; sums "$f"; done
}
good() { # 디렉터리 항목까지 포함한 `unzip -Z1` 모양
  echo "$G/"; echo "$G/kc-parent/"; echo "$G/kc-parent/1.2.2/"
  pom_only kc-parent 1.2.2; pom_only kc-bom 1.2.2; jar_comp kc-core 1.2.2
}

run() { node "$GUARD" "$@" --root="$R" 2>&1; }
status() { node "$GUARD" "$@" --root="$R" >/dev/null 2>&1 && echo 0 || echo $?; }

# 1. 정상 번들은 통과하고, 기대 집합을 pom 에서 읽었다고 말한다
good > "$FIX/good.txt"
assert_eq 0 "$(status "$FIX/good.txt")" "정상 번들(부모·bom·core)은 통과한다"
assert_contains "$(run "$FIX/good.txt")" "구성요소 3/3 (kc-parent · kc-bom · kc-core)" "기대 집합은 pom 의 artifactId 에서 온다(디렉터리 이름·주석·<parent> 가 아니다)"

# 2. Maven 3.10 + 0.11.x 가 낸 모양 — v1.2.0·v1.2.1 이 거부된 바로 그 번들
{ good
  echo "$G/kc-core/maven-metadata-local.xml"
  echo "$G/kc-core/1.2.2/_remote.repositories"; sums "$G/kc-core/1.2.2/_remote.repositories"
  echo ".locks/io.github.xzawed/kc-core-1.2.2.pom.lock"
} > "$FIX/m310.txt"
assert_eq 1 "$(status "$FIX/m310.txt")" "로컬 저장소 장부가 든 번들(1.2.0·1.2.1 의 모양)은 실패한다"
assert_contains "$(run "$FIX/m310.txt")" "로컬 저장소 장부가 번들에 있다: $G/kc-core/maven-metadata-local.xml" "아티팩트 디렉터리의 maven-metadata-local.xml 을 이름으로 짚는다"
assert_contains "$(run "$FIX/m310.txt")" ".locks/" ".locks 디렉터리도 짚는다"

# 3. 장부 규칙만 잡는 자리 — 좌표 접두가 맞는 `.lastUpdated`(다른 규칙은 통과시킨다)
{ good; echo "$G/kc-core/1.2.2/kc-core-1.2.2.jar.lastUpdated"; } > "$FIX/lastupdated.txt"
assert_eq 1 "$(status "$FIX/lastupdated.txt")" "좌표 접두가 맞아도 .lastUpdated 는 장부다"

# 4. 구성요소에 .pom 이 없다
good | grep -v -F "$G/kc-core/1.2.2/kc-core-1.2.2.pom" > "$FIX/nopom.txt"
assert_eq 1 "$(status "$FIX/nopom.txt")" "jar 만 있고 .pom 이 없는 구성요소는 실패한다"
assert_contains "$(run "$FIX/nopom.txt")" ".pom 이 없는 구성요소: $G/kc-core/1.2.2" ".pom 이 없는 구성요소를 이름으로 짚는다"

# 5. 게시 모듈이 빠졌다 / 게시 밖 모듈이 들어왔다
good | grep -v -F "/kc-bom/" > "$FIX/missing.txt"
assert_eq 1 "$(status "$FIX/missing.txt")" "게시해야 할 모듈(bom)이 없으면 실패한다"
assert_contains "$(run "$FIX/missing.txt")" "번들에 없는 게시 모듈: kc-bom" "빠진 모듈을 이름으로 짚는다"
{ good; jar_comp kc-examples 1.2.2; } > "$FIX/extra.txt"
assert_eq 1 "$(status "$FIX/extra.txt")" "excludeArtifacts 의 모듈이 번들에 있으면 실패한다"

# 6. 구성요소 디렉터리 밖 · 좌표와 다른 이름
{ good; echo "$G/kc-core/NOTICE.txt"; } > "$FIX/shallow.txt"
assert_eq 1 "$(status "$FIX/shallow.txt")" "버전 디렉터리 밖(아티팩트 디렉터리)의 파일은 실패한다"
{ good; echo "$G/kc-core/1.2.2/other-1.2.2.jar"; } > "$FIX/misnamed.txt"
assert_eq 1 "$(status "$FIX/misnamed.txt")" "좌표와 다른 이름의 파일은 실패한다"
{ good; echo "com/example/x/1.0/x-1.0.pom"; } > "$FIX/foreign.txt"
assert_eq 1 "$(status "$FIX/foreign.txt")" "그룹 경로 밖의 파일은 실패한다"

# 7. 윈도에서 만든 zip(역슬래시)과 stdin
good | tr / '\\' > "$FIX/win.txt"
assert_eq 0 "$(status "$FIX/win.txt")" "역슬래시 목록도 같은 판정을 받는다"
assert_eq 0 "$(good | node "$GUARD" - --root="$R" >/dev/null 2>&1 && echo 0 || echo $?)" "'-' 는 stdin 을 읽는다"

# 8. 공허 통과 금지
: > "$FIX/empty.txt"
assert_eq 1 "$(status "$FIX/empty.txt")" "빈 목록은 실패한다(게시 모듈이 전부 없다)"
mkdir -p "$FIX/norepo"
assert_eq 2 "$(node "$GUARD" "$FIX/good.txt" --root="$FIX/norepo" >/dev/null 2>&1 && echo 0 || echo $?)" "java/pom.xml 을 못 읽으면 2 로 멈춘다(빈 기대 집합으로 넘어가지 않는다)"

# 9. 적대 레그(Grok)가 찾은 「검사기는 통과, Central 은 거부」 자리 — Central 이 문서로 요구하는 것들
good | grep -v -F "$G/kc-core/1.2.2/kc-core-1.2.2-sources.jar.sha1" > "$FIX/nosha1.txt"
assert_eq 1 "$(status "$FIX/nosha1.txt")" "파일마다 .md5·.sha1 이 있어야 한다(.sha1 하나가 빠져도 실패)"
{ good; echo "$G/kc-core/1.2.2/kc-core-1.2.2X.jar"; sums "$G/kc-core/1.2.2/kc-core-1.2.2X.jar"; } > "$FIX/junk.txt"
assert_eq 1 "$(status "$FIX/junk.txt")" "좌표 접두 뒤에는 '.' 이나 '-' 만 온다(…1.2.2X.jar 는 다른 판의 이름이다)"
good | grep -v -E "kc-core-1\.2\.2-javadoc\.jar" > "$FIX/nojavadoc.txt"
assert_eq 1 "$(status "$FIX/nojavadoc.txt")" "jar 구성요소는 -javadoc.jar 가 있어야 한다"
good | grep -v -E "kc-core-1\.2\.2\.jar" > "$FIX/nomain.txt"
assert_eq 1 "$(status "$FIX/nomain.txt")" "-sources·-javadoc 만 있고 본 jar 가 없으면 실패한다"
{ pom_only kc-parent 1.2.2; pom_only kc-bom 1.2.2; jar_comp kc-core 1.2.3; } > "$FIX/mixed.txt"
assert_eq 1 "$(status "$FIX/mixed.txt")" "구성요소의 판이 갈리면 실패한다(리액터는 한 판이다)"
{ good; jar_comp kc-core 1.2.3; } > "$FIX/twover.txt"
assert_eq 1 "$(status "$FIX/twover.txt")" "한 아티팩트의 두 판이 함께 있으면 실패한다"
{ pom_only kc-parent 1.2.2-SNAPSHOT; pom_only kc-bom 1.2.2-SNAPSHOT; jar_comp kc-core 1.2.2-SNAPSHOT; } > "$FIX/snap.txt"
assert_eq 1 "$(status "$FIX/snap.txt")" "SNAPSHOT 판은 실패한다"
good | sed 's#^#./#' > "$FIX/dotslash.txt"
assert_eq 0 "$(status "$FIX/dotslash.txt")" "'./' 로 시작하는 항목도 같은 판정을 받는다"
# 대조군 — 서명은 이 가드의 범위 밖이다(release-bundle 은 -Dgpg.skip 이라 .asc 가 없다)
good | grep -v -E '\.asc$' > "$FIX/unsigned.txt"
assert_eq 0 "$(status "$FIX/unsigned.txt")" "서명 없는 번들은 통과한다(서명은 범위 밖 — CI 번들은 서명하지 않는다)"

# 10. 실제 트리 — 기대 집합을 이 저장소의 pom 이 정한다(여기서 손으로 적지 않는다)
real_ids="$(node "$GUARD" "$FIX/empty.txt" --root="$REPO" 2>&1 | sed -n 's/.*번들에 없는 게시 모듈: \([^ ]*\).*/\1/p' | sort | tr '\n' ' ')"
assert_contains "$real_ids" "keycloak-sdk-auth" "실제 트리의 기대 집합에 auth 가 있다"
assert_contains "$real_ids" "keycloak-sdk-parent" "실제 트리의 기대 집합에 부모 pom 이 있다"
assert_not_contains "$real_ids" "keycloak-sdk-examples" "실제 트리의 기대 집합은 excludeArtifacts 를 뺀다"

assert_report
