#!/usr/bin/env sh
# 통합 전용 커버리지 장부의 **하네스 소유** 자가테스트(`harness:install` — 등록부 integration-ledger-blind-to-harness-runs).
#
# 왜 따로인가: 변이 레코드 15 개(연결의 고리마다 하나)가 프로브마다 이 시험을 두 번(기준선 · 변이) 돈다. 2,900 줄짜리
# `test-integration-coverage.sh` 를 겨누면 변이 스윕이 19 분에서 62 분이 됐다(실측: #1103 → #1104 의 PR 스윕). 이 절은 다른
# 절과 상태를 나누지 않으므로 떼어 내고, 레코드는 이 파일을 겨눈다.
#
# 픽스처 · 데이터의 출처는 `test-integration-coverage.sh` 의 머리가 소유한다 — 준비 함수는 둘이 함께 소싱하는 `ic-fixture.sh`.
# ⚠️ 도구 경로(`TOOL` · `BOUNDARY`)는 이 파일에 둔다 — 변이 스윕이 M1 짝을 시험 파일의 글자에서 파생한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
FIX="$DIR/fixtures/integration-coverage"
TOOL="$DIR/../integration-coverage.mjs"
BOUNDARY="$DIR/../coverage-boundary.mjs"
. "$DIR/ic-fixture.sh"

# ── (6) 하네스 소유(`harness` — 등록부 integration-ledger-blind-to-harness-runs) ─────────────────────────────
# 통합 스위트가 안 돌리지만 설치 하네스가 실서버에 대고 돌리는 파일(java 의 예제)은 `harness:install` 이 소유한다 — 그 연결을
# 트리에서 확인할 때만이다. 픽스처의 harness/install/consume 세 파일(이미지 · 퀵스타트 pom · 실행 스크립트)이 QuickStart 를 돌린다.
HC="$T/harness/install/consume"
QS="java/kc-examples/src/main/java/kc/examples/QuickStart.java"
harness_on() {
  sed -i "s#\"$QS:QuickStart.\\(env\\|main\\)\": \"open-masking\"#\"$QS:QuickStart.\\1\": \"harness:install\"#" "$T/scripts/integration-coverage.json"
  sed -i "s|^  \"java\": {\$|  \"java\": {\n    \"harness\": { \"$QS\": { \"image\": \"harness/install/consume/java.Dockerfile\", \"project\": \"harness/install/consume/java-quickstart-pom.xml\", \"entrypoint\": \"harness/install/consume/java-run.sh\" } },|" "$T/scripts/integration-coverage.json"
  assert_eq 2 "$(grep -c '": "harness:install"' "$T/scripts/integration-coverage.json")" "(두 소유자가 하네스로 바뀌었는지 먼저 본다)"
  assert_contains "$(cat "$T/scripts/integration-coverage.json")" "\"harness\": { \"$QS\": {" "(기록이 착지했는지 먼저 본다)"
}
# 연결 하나를 끊으면 하네스 소유 둘이 다 DRIFT(1)다 — 까닭은 연결의 어느 고리인지를 댄다.
harness_broken() { # <why> <what>
  run check "$T"
  assert_eq 1 "$RC" "[harness] $2 — check 는 exit 1 — 출력: $OUT"
  assert_contains "$OUT" "DRIFT [java] $QS:QuickStart.main is owned by harness:install, but the link does not hold — $1" "[harness] $2 — 까닭"
  assert_contains "$OUT" "DRIFT [java] $QS:QuickStart.env is owned by harness:install, but the link does not hold — " "[harness] $2 — 같은 파일의 다른 소유자도"
  assert_line "$OUT" "[java] harness: $QS ← harness/install/consume/java.Dockerfile (the link does not hold)" "[harness] $2 — check 의 연결 줄"
}
# 양성 — 연결이 서면 check · report 둘 다 0 이고, 미실행 목록에는 하네스 소유로 남는다(숨기지 않는다).
fresh; harness_on
run check "$T"
assert_eq 0 "$RC" "[harness] 연결이 서면 check 는 exit 0 — 출력: $OUT"
assert_line "$OUT" "[java] harness: $QS ← harness/install/consume/java.Dockerfile (linked)" "[harness] check 가 연결을 요약한다"
assert_line "$OUT" "integration-coverage check: OK — go 3 · python 3 · node 2 · rust 3 · php 2 · ruby 3 · dotnet 2 · java 2 · kotlin 2 files pinned · 94 owner entries, 92 open · 2 linked to the install harness" "[harness] 요약이 하네스 소유를 따로 센다"
run report java "$T" --out "$D"
assert_eq 0 "$RC" "[harness] 연결이 서면 report 도 exit 0 — 출력: $OUT"
assert_line "$OUT" "  NEVER $QS:8 QuickStart.main · 2 lines · owner harness:install" "[harness] 미실행 목록에 하네스 소유로 남는다"
assert_line "$OUT" "integration-coverage [java]: OK — lines 22/31 (71.0%) · bodies 18/27 (66.7%) · 5 never-executed functions, all owned by open registry items or the install harness" "[harness] 통과 요약"
# 양성 — 같은 뜻의 다른 꼴도 선다: CRLF(윈도 체크아웃) · JSON 꼴 COPY · ENTRYPOINT + CMD · 이어진 명령 속 주석 줄.
fresh; harness_on
sed -i 's/$/\r/' "$HC/java.Dockerfile" "$HC/java-quickstart-pom.xml" "$HC/java-run.sh"
# CR 은 바이트로 센다 — Git for Windows 의 grep 은 줄 끝 CR 을 떼고 맞춰 `\r$` 를 0 으로 센다(실측).
assert_eq 7 "$(tr -cd '\r' < "$HC/java.Dockerfile" | wc -c | tr -d ' ')" "(CRLF 가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 0 "$RC" "[harness] CRLF 세 파일도 연결이 선다 — 출력: $OUT"
fresh; harness_on
sed -i 's#^COPY java/kc-examples/src/main/java/kc \./quickstart/src/main/java/kc$#COPY ["java/kc-examples/src/main/java/kc", "./quickstart/src/main/java/kc"]#; s#^CMD \["sh", "/work/run.sh"\]$#ENTRYPOINT ["sh"]\nCMD ["/work/run.sh"]#' "$HC/java.Dockerfile"
assert_contains "$(cat "$HC/java.Dockerfile")" 'ENTRYPOINT ["sh"]' "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 0 "$RC" "[harness] JSON 꼴 COPY 와 ENTRYPOINT + CMD 도 연결이 선다 — 출력: $OUT"
fresh; harness_on
sed -i 's#^COPY java/kc-examples/src/main/java/kc \./quickstart/src/main/java/kc$#COPY java/kc-examples/src/main/java/kc \\\n\# 이어진 명령 속 주석 줄은 명령을 끊지 않는다\n  ./quickstart/src/main/java/kc#' "$HC/java.Dockerfile"
sed -i 's#^   mvn -B#\# 이어진 조건 속 주석 줄\n   mvn -B#' "$HC/java-run.sh"
assert_contains "$(cat "$HC/java.Dockerfile")" "# 이어진 명령 속 주석 줄" "(변이가 착지했는지 먼저 본다)"
assert_contains "$(cat "$HC/java-run.sh")" "# 이어진 조건 속 주석 줄" "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 0 "$RC" "[harness] 이어진 명령 속 주석 줄은 버리고 잇는다(Docker 와 같은 순서 — 실측: BuildKit 이 그 COPY 를 했다) — 출력: $OUT"
fresh; harness_on
sed -i 's#^WORKDIR /work$#WORKDIR /work\nRUN mkdir -p /work/quickstart#' "$HC/java.Dockerfile"
assert_contains "$(cat "$HC/java.Dockerfile")" "RUN mkdir -p /work/quickstart" "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 0 "$RC" "[harness] COPY 앞의 RUN 은 복사한 파일을 못 고친다 — 연결이 선다 — 출력: $OUT"
# 음성 — image: 예제를 안 넣는다 · 사본을 넣는다 · 뒤의 COPY 가 덮는다 · 마지막 단계가 아니다 · WORKDIR 를 못 푼다 · CMD 가 다르다.
fresh; harness_on
sed -i 's|^COPY java/kc-examples|# COPY java/kc-examples|' "$HC/java.Dockerfile"
assert_contains "$(cat "$HC/java.Dockerfile")" "# COPY java/kc-examples" "(변이가 착지했는지 먼저 본다)"
harness_broken "harness/install/consume/java.Dockerfile does not COPY $QS into the final image" "예제 COPY 를 주석으로"
fresh; harness_on
sed -i 's|^COPY java/kc-examples/src/main/java/kc |COPY harness/install/quickstart/java/kc |' "$HC/java.Dockerfile"
assert_contains "$(cat "$HC/java.Dockerfile")" "COPY harness/install/quickstart/java/kc " "(변이가 착지했는지 먼저 본다)"
harness_broken "harness/install/consume/java.Dockerfile does not COPY $QS into the final image" "사본을 넣으면"
fresh; harness_on
printf 'COPY harness/install/quickstart/java ./quickstart/src/main/java/kc/examples\n' >> "$HC/java.Dockerfile"
harness_broken "harness/install/consume/java.Dockerfile: a later COPY to /work/quickstart/src/main/java/kc/examples may overwrite $QS at /work/quickstart/src/main/java/kc/examples/QuickStart.java" "뒤의 COPY 가 그 자리를 덮으면"
fresh; harness_on
printf 'RUN printf "class QuickStart {}" > /work/quickstart/src/main/java/kc/examples/QuickStart.java\n' >> "$HC/java.Dockerfile"
harness_broken "harness/install/consume/java.Dockerfile: a RUN after the COPY of $QS may rewrite it at /work/quickstart/src/main/java/kc/examples/QuickStart.java" "뒤의 RUN 이 그 파일을 고칠 수 있으면"
fresh; harness_on
printf 'FROM alpine:3.20\nCMD ["sh", "/work/run.sh"]\n' >> "$HC/java.Dockerfile"
harness_broken "harness/install/consume/java.Dockerfile does not COPY $QS into the final image" "마지막 단계가 넣지 않으면"
fresh; harness_on
sed -i 's#^COPY java/kc-examples#COPY --from=build java/kc-examples#' "$HC/java.Dockerfile"
assert_contains "$(cat "$HC/java.Dockerfile")" "COPY --from=build java/kc-examples" "(변이가 착지했는지 먼저 본다)"
harness_broken "harness/install/consume/java.Dockerfile does not COPY $QS into the final image" "다른 단계에서 가져오면(--from — 빌드 맥락의 그 파일이 아니다)"
fresh; harness_on
sed -i '/^WORKDIR /d' "$HC/java.Dockerfile"
assert_not_contains "$(cat "$HC/java.Dockerfile")" "WORKDIR" "(변이가 착지했는지 먼저 본다)"
harness_broken "harness/install/consume/java.Dockerfile does not COPY $QS into the final image" "상대 대상을 풀 WORKDIR 가 없으면"
fresh; harness_on
sed -i 's|^CMD \["sh", "/work/run.sh"\]$|CMD ["sh", "/work/other.sh"]|' "$HC/java.Dockerfile"
assert_contains "$(cat "$HC/java.Dockerfile")" "/work/other.sh" "(변이가 착지했는지 먼저 본다)"
harness_broken "harness/install/consume/java.Dockerfile: CMD/ENTRYPOINT does not run /work/run.sh (harness/install/consume/java-run.sh)" "CMD 가 다른 것을 돌리면"
# 음성 — project: 예제가 프로젝트 밖에 떨어진다 · 진입점이 다른 클래스 · 주석 속에만 있다 · 둘이다.
fresh; harness_on
sed -i 's|\./quickstart/src/main/java/kc$|./other/src/main/java/kc|' "$HC/java.Dockerfile"
assert_contains "$(cat "$HC/java.Dockerfile")" "./other/src/main/java/kc" "(변이가 착지했는지 먼저 본다)"
harness_broken "$QS lands at /work/other/src/main/java/kc/examples/QuickStart.java, outside the source root /work/quickstart/src/main/java/ of /work/quickstart/pom.xml" "예제가 프로젝트 밖에 떨어지면"
fresh; harness_on
sed -i 's|<exec.mainClass>kc.examples.QuickStart</exec.mainClass>|<exec.mainClass>kc.examples.Other</exec.mainClass>|' "$HC/java-quickstart-pom.xml"
assert_contains "$(cat "$HC/java-quickstart-pom.xml")" "kc.examples.Other" "(변이가 착지했는지 먼저 본다)"
harness_broken "harness/install/consume/java-quickstart-pom.xml must name kc.examples.QuickStart as its one <exec.mainClass> (found kc.examples.Other)" "진입점이 다른 클래스면"
fresh; harness_on
sed -i 's|^    <exec.mainClass>kc.examples.QuickStart</exec.mainClass>$|    <!-- <exec.mainClass>kc.examples.QuickStart</exec.mainClass> -->|' "$HC/java-quickstart-pom.xml"
assert_contains "$(cat "$HC/java-quickstart-pom.xml")" "<!-- <exec.mainClass>" "(변이가 착지했는지 먼저 본다)"
harness_broken "harness/install/consume/java-quickstart-pom.xml must name kc.examples.QuickStart as its one <exec.mainClass> (found none)" "진입점이 주석 속에만 있으면"
fresh; harness_on
sed -i 's|^  </properties>$|  </properties>\n  <profiles><profile><id>x</id><properties><exec.mainClass>kc.examples.Other</exec.mainClass></properties></profile></profiles>|' "$HC/java-quickstart-pom.xml"
assert_contains "$(cat "$HC/java-quickstart-pom.xml")" "<profiles>" "(변이가 착지했는지 먼저 본다)"
harness_broken "harness/install/consume/java-quickstart-pom.xml must name kc.examples.QuickStart as its one <exec.mainClass> (found kc.examples.QuickStart, kc.examples.Other)" "진입점이 둘이면"
# 실행을 끄거나 진입점을 플러그인 설정으로 바꾸면 그 클래스가 안 돈다(독립 레그 지목 — 실행 없이 성공한다).
for mut in '<build><plugins><plugin><artifactId>exec-maven-plugin</artifactId><configuration><skip>true</skip></configuration></plugin></plugins></build>' \
  '<build><plugins><plugin><artifactId>exec-maven-plugin</artifactId><configuration><mainClass>kc.examples.Other</mainClass></configuration></plugin></plugins></build>' \
  '<profiles><profile><id>s</id><properties><exec.skip>true</exec.skip></properties></profile></profiles>'; do
  fresh; harness_on
  sed -i "s#^</project>\$#  $mut\n</project>#" "$HC/java-quickstart-pom.xml"
  assert_contains "$(cat "$HC/java-quickstart-pom.xml")" "$mut" "(변이가 착지했는지 먼저 본다 — $mut)"
  harness_broken "harness/install/consume/java-quickstart-pom.xml overrides the run — <skip>, <exec.skip> or a plugin <mainClass>" "pom 이 실행을 바꾸면 — $mut"
done
# 음성 — entrypoint: 실행이 실패해도 표지가 서는 조건(|| · ; · ! · 파이프 · 배경) · 다른 프로젝트 · 표지가 다음 줄이 아니다 · 주석 처리.
RUNWHY="harness/install/consume/java-run.sh has no \`if … -f /work/quickstart/pom.xml … exec:java …; then\` whose condition fails when the run fails (no !, |, ; or lone &) and runs the project as it is (no -Dexec.*, -Dskip, --file or second -f)"
for mut in '|| true' '; true' '| tee /tmp/qs.out' '\& true'; do
  fresh; harness_on
  sed -i "s#exec:java >/tmp/qs.log 2>&1; then#exec:java >/tmp/qs.log 2>\\&1 $mut; then#" "$HC/java-run.sh"
  assert_contains "$(cat "$HC/java-run.sh")" "2>&1 $(printf '%s' "$mut" | sed 's#^\\##'); then" "(변이가 착지했는지 먼저 본다 — $mut)"
  harness_broken "$RUNWHY" "조건에 $mut"
done
# 실행을 끄거나(-Dexec.skip · -Dskip) 진입점이나 pom 을 바꾸면 그 예제가 안 돈다(독립 레그 지목 — 실행 없이 성공한다).
for mut in '-Dexec.skip=true' '-Dexec.mainClass=kc.examples.Other' '-Dskip=true' '-f /work/app/pom.xml' '--file=/work/app/pom.xml'; do
  fresh; harness_on
  sed -i "s#compile exec:java >/tmp/qs.log#compile exec:java $mut >/tmp/qs.log#" "$HC/java-run.sh"
  assert_contains "$(cat "$HC/java-run.sh")" "exec:java $mut >/tmp/qs.log" "(변이가 착지했는지 먼저 본다 — $mut)"
  harness_broken "$RUNWHY" "실행 인자에 $mut"
done
fresh; harness_on
sed -i 's#^if KEYCLOAK_URL#if ! KEYCLOAK_URL#' "$HC/java-run.sh"
assert_contains "$(cat "$HC/java-run.sh")" "if ! KEYCLOAK_URL" "(변이가 착지했는지 먼저 본다)"
harness_broken "$RUNWHY" "조건이 부정이면"
fresh; harness_on
sed -i 's#-f /work/quickstart/pom.xml#-f /work/app/pom.xml#' "$HC/java-run.sh"
assert_contains "$(cat "$HC/java-run.sh")" "-f /work/app/pom.xml" "(변이가 착지했는지 먼저 본다)"
harness_broken "$RUNWHY" "다른 프로젝트를 돌리면"
fresh; harness_on
sed -i 's#^if KEYCLOAK_URL#\# if KEYCLOAK_URL#' "$HC/java-run.sh"
assert_contains "$(cat "$HC/java-run.sh")" "# if KEYCLOAK_URL" "(변이가 착지했는지 먼저 본다)"
harness_broken "$RUNWHY" "실행을 주석으로"
fresh; harness_on
sed -i '/^  : > "\$STATUS\/quickstart.ok"$/d' "$HC/java-run.sh"
printf ': > "$STATUS/quickstart.ok"\n' >> "$HC/java-run.sh"
assert_eq ': > "$STATUS/quickstart.ok"' "$(tail -n 1 "$HC/java-run.sh")" "(변이가 착지했는지 먼저 본다)"
harness_broken 'harness/install/consume/java-run.sh: the line after that if is not : > "$STATUS/quickstart.ok"' "표지가 실행과 무관하게 서면"
# 표지를 쓰는 줄은 하나다 — else 갈래나 실행 앞에서도 쓰면 실패해도 표지가 선다(독립 레그가 「실수로 가장 일어나기 쉬운 것」으로 지목).
# 위의 `rm -f` 줄(픽스처 · 실제 스크립트 모두)은 지우는 줄이라 된다 — 양성 대조가 그것을 이미 지난다.
fresh; harness_on
sed -i 's#^fi$#else\n  : > "$STATUS/quickstart.ok"\nfi#' "$HC/java-run.sh"
assert_eq 2 "$(grep -c '^  : > "\$STATUS/quickstart.ok"$' "$HC/java-run.sh")" "(변이가 착지했는지 먼저 본다)"
harness_broken 'harness/install/consume/java-run.sh: quickstart.ok is written outside that if too — : > "$STATUS/quickstart.ok"' "else 갈래도 표지를 쓰면"
fresh; harness_on
sed -i 's#^if KEYCLOAK_URL#touch "$STATUS/quickstart.ok"\nif KEYCLOAK_URL#' "$HC/java-run.sh"
assert_contains "$(cat "$HC/java-run.sh")" 'touch "$STATUS/quickstart.ok"' "(변이가 착지했는지 먼저 본다)"
harness_broken 'harness/install/consume/java-run.sh: quickstart.ok is written outside that if too — touch "$STATUS/quickstart.ok"' "실행 앞에서 표지를 만들면"
fresh; harness_on
rm "$HC/java-run.sh"
harness_broken "entrypoint harness/install/consume/java-run.sh is not in the tree" "실행 스크립트가 없으면"
# report 도 같은 판정이다(소유 판정 하나를 둘이 쓴다).
fresh; harness_on
sed -i 's|^COPY java/kc-examples|# COPY java/kc-examples|' "$HC/java.Dockerfile"
run report java "$T" --out "$D"
assert_eq 1 "$RC" "[harness] report 도 끊긴 연결은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] $QS:QuickStart.env is owned by harness:install, but the link does not hold — harness/install/consume/java.Dockerfile does not COPY $QS into the final image" "[harness] report 의 까닭"
assert_line "$OUT" "  total lines 22/31 71.0% · bodies 18/27 66.7%" "[harness] 소유 문제는 수치를 지우지 않는다"
# 음성 — 기록: 없는 기록을 가리키는 소유자 · 쓰이지 않는 기록 · 핀 밖 파일의 기록 · java 밖 언어의 기록.
fresh
sed -i "s#\"$QS:QuickStart.main\": \"open-masking\"#\"$QS:QuickStart.main\": \"harness:install\"#" "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 1 "$RC" "[harness] 기록 없는 하네스 소유는 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] $QS:QuickStart.main is owned by harness:install, but scripts/integration-coverage.json has no java.harness record for $QS" "[harness] 기록이 없다고 댄다"
fresh; harness_on
sed -i "s#\"$QS:QuickStart.\\(env\\|main\\)\": \"harness:install\"#\"$QS:QuickStart.\\1\": \"open-masking\"#" "$T/scripts/integration-coverage.json"
assert_eq 0 "$(grep -c '": "harness:install"' "$T/scripts/integration-coverage.json")" "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 1 "$RC" "[harness] 쓰이지 않는 기록은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] harness record $QS is not used by any owner entry — drop it" "[harness] 낡은 기록"
fresh; harness_on
sed -i "s#\"harness\": { \"$QS\"#\"harness\": { \"java/kc-examples/src/main/java/kc/examples/Gone.java\"#" "$T/scripts/integration-coverage.json"
run check "$T"
assert_eq 1 "$RC" "[harness] 핀 밖 파일의 기록은 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [java] harness record java/kc-examples/src/main/java/kc/examples/Gone.java names a file outside the pin" "[harness] 핀 밖 기록"
fresh
KQ="kotlin/src/main/kotlin/kc/examples/QuickStart.kt"
sed -i "s#\"$KQ:QuickStartKt.main\": \"open-masking\"#\"$KQ:QuickStartKt.main\": \"harness:install\"#" "$T/scripts/integration-coverage.json"
sed -i "s|^  \"kotlin\": {\$|  \"kotlin\": {\n    \"harness\": { \"$KQ\": { \"image\": \"harness/install/consume/java.Dockerfile\", \"project\": \"harness/install/consume/java-quickstart-pom.xml\", \"entrypoint\": \"harness/install/consume/java-run.sh\" } },|" "$T/scripts/integration-coverage.json"
assert_contains "$(cat "$T/scripts/integration-coverage.json")" "\"harness\": { \"$KQ\"" "(변이가 착지했는지 먼저 본다)"
run check "$T"
assert_eq 1 "$RC" "[harness] java 밖 언어의 기록은 확인할 수 없어 exit 1 — 출력: $OUT"
assert_contains "$OUT" "DRIFT [kotlin] $KQ:QuickStartKt.main is owned by harness:install, but the link does not hold — this reader checks the java link only (Maven exec:java) — a kotlin record cannot be verified" "[harness] java 만 읽는다"
# 꼴 — 키가 모자라거나 남거나 배열이면 무결성 실패(2). 소유가 조용히 꺼지면 안 된다.
for bad in "{ \"$QS\": { \"image\": \"harness/install/consume/java.Dockerfile\" } }" \
  "{ \"$QS\": { \"image\": \"a\", \"project\": \"b\", \"entrypoint\": \"c\", \"extra\": \"d\" } }" \
  "{ \"$QS\": { \"image\": \"a\", \"project\": \"\", \"entrypoint\": \"c\" } }" \
  "[\"$QS\"]"; do
  fresh
  sed -i "s|^  \"java\": {\$|  \"java\": {\n    \"harness\": $bad,|" "$T/scripts/integration-coverage.json"
  assert_contains "$(cat "$T/scripts/integration-coverage.json")" "\"harness\": $bad," "(변이가 착지했는지 먼저 본다)"
  run check "$T"
  assert_eq 2 "$RC" "[harness] 틀린 꼴의 기록은 2 — $bad — 출력: $OUT"
  assert_contains "$OUT" "FAIL [java] scripts/integration-coverage.json: java.harness must map a pinned file to { entrypoint, image, project } (repository paths)" "[harness] 꼴을 지목한다 — $bad"
done

assert_report
