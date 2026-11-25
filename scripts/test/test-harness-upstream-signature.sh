#!/usr/bin/env sh
# 실패한 예약 harness 로그가 **상류 다운로드 거절**인가 — `scripts/harness-upstream-signature.mjs` 의 종료코드 셋을 고정한다
# (0 맞음 · 1 맞는 줄 없음 = 제품 실패 · 2 판정 불가). 그 0 이 `.github/workflows/harness-rerun.yml` 의 「한 번 다시 돌린다」를 연다.
#
# ⚠️ **실측이 이 판정을 만들었다**(등록부 harness-central-refuses-runner). 예약 harness 최근 100 회 중 실패 28 —
#   상류 거절 4: 44979301872(2026-11-22 Central `(absent)` + Gradle 플러그인) · 42441515425(11-08) · 32548583740(08-22)
#                (둘 다 composer zipball HTTP/2 504) · 35417940151(09-19 Gradle 포털 DNS) — 새 러너의 재실행이 통과했다.
#   제품 실패 23 — 다시 돌려 덮으면 안 된다. 그래서 판정은 **좁다**: 거절 모양 AND 다운로드 맥락이 한 줄에 함께 있어야 한다.
#   로그 만료 1: 32211733068(08-19 — API 가 HTTP 410) — 빈 로그는 「서명 없음」(1)이 아니라 판정 불가(2)다.
#
# 세 묶음 — 실제 줄은 그대로 옮겼다(gh 의 잡 · 스텝 · 시각 칸만 뺐다):
#   양성       인수인계 `positive-lines.txt` 의 줄 열(11-24 PR 실행의 429 포함) → 0, 그리고 맞은 줄을 찍는다.
#   음성       제품 실패 로그 23 개의 실제 줄 — `429 complete` · `(timeout 240s)` · `Fetching timeout` · `504 kB/s` 처럼 낱말만
#              닮은 줄 포함 — · 상류 로그의 성공 줄 · 제품 자신의 낱말(SDK 의 `Read timed out` · JDK 의 `Connection reset` ·
#              node 의 `read ECONNRESET`) → 1.
#              근접 대조군(지어낸 줄): 실제 양성 줄에서 **한 부분만** 바꾼 줄 — 거절 모양을 지우거나(429 → 401 · 504 → 404) 맥락을
#              하네스 자신의 레지스트리로 바꾸거나(mvn-repo · mvn-repo-kotlin · satis-web · 컴포즈 서비스 keycloak) 서명의 꼬리를 바꾼다
#              (해석 출처 절을 뗀 플러그인 문구 · `(present, but unavailable)`) — → 1. 넓어진 서명은 여기서 운다.
#   판정 불가  인자 없음 · 둘 · 없는 파일 · 디렉터리 · 빈 로그 · 공백만 → 2.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
SIG="$ROOT/scripts/harness-upstream-signature.mjs"

_t="$(mktemp -d)"
trap 'rm -rf "$_t"' EXIT

# 판정기가 없으면 node 가 exit 1 을 내 음성이 전부 「맞게」 지나간다 — 먼저 크게 운다.
assert_eq "있음" "$([ -f "$SIG" ] && echo 있음 || echo 없음)" "판정기가 없다: $SIG"

# hus <인자…> — 판정기를 돌려 종료코드를 $_t/rc, 표준출력을 $_t/out 에 남긴다(단언은 부모 셸에서 한다).
hus() { _hr=0; node "$SIG" "$@" < /dev/null > "$_t/out" 2> "$_t/err" || _hr=$?; echo "$_hr" > "$_t/rc"; }
# hus_line <줄> — 그 한 줄만 담은 로그를 판정한다.
hus_line() { printf '%s\n' "$1" > "$_t/one.log"; hus "$_t/one.log"; }
hus_rc() { cat "$_t/rc"; }
hus_trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# ── 양성 — 인수인계 positive-lines.txt 그대로. 줄마다 서명 하나가 맞는다(central-429 · central-absent · github-dist-5xx ·
#    gradle-portal-get · gradle-portal-dns · gradle-plugin).
HUS_POS="$(cat <<'EOF'
#15 32.80 [ERROR] Non-resolvable import POM: The following artifacts could not be resolved: org.junit:junit-bom:pom:6.1.3 (absent): Could not transfer artifact org.junit:junit-bom:pom:6.1.3 from/to central (https://repo.maven.apache.org/maven2): status code: 429, reason phrase: Too Many Requests (429) @ line 84, column 19
#15 32.80 [ERROR]     Non-resolvable import POM: The following artifacts could not be resolved: org.junit:junit-bom:pom:6.1.3 (absent): Could not transfer artifact org.junit:junit-bom:pom:6.1.3 from/to central (https://repo.maven.apache.org/maven2): status code: 429, reason phrase: Too Many Requests (429) @ line 84, column 19 -> [Help 2]
#15 1.930 [ERROR] Non-resolvable import POM: The following artifacts could not be resolved: org.junit:junit-bom:pom:6.1.3 (absent): Could not find artifact org.junit:junit-bom:pom:6.1.3 in central (https://repo.maven.apache.org/maven2) @ line 84, column 19
#15 1.930 [ERROR]     Non-resolvable import POM: The following artifacts could not be resolved: org.junit:junit-bom:pom:6.1.3 (absent): Could not find artifact org.junit:junit-bom:pom:6.1.3 in central (https://repo.maven.apache.org/maven2) @ line 84, column 19 -> [Help 2]
#17 24.27     Failed to download psr/http-server-handler from dist: The "https://api.github.com/repos/php-fig/http-server-handler/zipball/84c4fb66179be4caaf8e97bd239203245302e7d4" file could not be downloaded (HTTP/2 504 )
#17 25.83     Failed to download psr/clock from dist: The "https://api.github.com/repos/php-fig/clock/zipball/e41a24703d4560fd0acb709162f73b8adfc3aa0d" file could not be downloaded (HTTP/2 504 )
                > Could not GET 'https://plugins-artifacts.gradle.org/org.jetbrains.kotlin/kotlin-gradle-plugin/2.2.20/b9c3fd2ebd5484d60c5fe0db7aa10878303eeddfc93f942f735c07ba998187cc/kotlin-gradle-plugin-2.2.20.pom'.
                   > plugins-artifacts.gradle.org: Try again
#15 23.70 Plugin [id: 'com.vanniktech.maven.publish', version: '0.37.0'] was not found in any of the following sources:
#15 28.63 Plugin [id: 'com.vanniktech.maven.publish', version: '0.37.0'] was not found in any of the following sources:
EOF
)"
_np=0
while IFS= read -r _l; do
  [ -n "$_l" ] || continue
  _np=$((_np + 1))
  hus_line "$_l"
  assert_eq "0" "$(hus_rc)" "[양성] 상류 다운로드 거절 줄을 놓쳤다(종료코드): $_l"
  assert_contains "$(cat "$_t/out")" "$(hus_trim "$_l")" "[양성] 맞은 줄을 찍지 않았다: $_l"
done <<EOF
$HUS_POS
EOF
assert_eq "10" "$_np" "[양성] 양성 줄이 10 개가 아니다 — 목록이 깨졌나?"

# ── 음성 — 제품 실패 로그 23 개(2026-09-08 ~ 11-06)의 실제 줄 · 상류 로그(09-19 · 11-08)의 성공 줄 · 제품 자신의 낱말.
#    k6 의 `429 complete`/`504 complete` · 빌드킷 시각 `.429` 가 붙은 다운로드 · Central 에서 받은 `504 kB/s` · 이름이 failureaccess ·
#    timeout 인 의존성 · 헬스 대기의 `(timeout 240s)` · 「could not」 + URL — 거절 모양이나 다운로드 맥락 **하나만** 가진 줄들이다.
#    마지막 셋은 로그가 아니라 제품의 문구다: SDK 의 기한 초과(python deadline.py · java/kotlin 의 LATE — 30 s 로 채움) ·
#    kotlin ConnectionReuseTest 가 서버에서 본 JDK 의 `Connection reset` · node transport 시험의 `read ECONNRESET`.
HUS_NEG="$(cat <<'EOF'
running (0m06.0s), 10/10 VUs, 429 complete and 0 interrupted iterations
running (0m10.0s), 10/10 VUs, 504 complete and 0 interrupted iterations
#10 6.429   Downloading idna-3.20-py3-none-any.whl.metadata (7.2 kB)
#16 1.429 go: downloading github.com/pmezard/go-difflib v1.0.0
#18 1.429   Downloaded base16ct v0.2.0
#12 2.039 Downloading httptools-0.8.0-cp312-cp312-musllinux_1_2_x86_64.whl (509 kB)
[INFO] Downloaded from central: https://repo.maven.apache.org/maven2/org/apache/maven/plugin-tools/maven-plugin-tools/3.15.1/maven-plugin-tools-3.15.1.pom (18 kB at 504 kB/s)
[INFO] Downloading from central: https://repo.maven.apache.org/maven2/com/google/guava/failureaccess/1.0.1/failureaccess-1.0.1.pom
#13 2.446 Fetching timeout 0.6.1
[2026-09-12 03:13:51] wait_healthy: waiting for http://localhost:9000/health/ready (timeout 240s)
Composer could not detect the root package (harness/php-satis) version, defaulting to '1.0.0'. See https://getcomposer.org/root-version
== [suite] 실패: dotnet ruby ==
[install-matrix] 실패한 언어: php, rust
##[error]Process completed with exit code 1.
    Resolved plugin [id: 'org.jetbrains.kotlin.jvm', version: '2.2.20']
    Resource missing. [HTTP HEAD: https://plugins.gradle.org/m2/org/jetbrains/kotlin/jvm/org.jetbrains.kotlin.jvm.gradle.plugin/2.2.20/org.jetbrains.kotlin.jvm.gradle.plugin-2.2.20.jar]
#17 20.39   - Downloading psr/clock (1.0.0)
Read timed out: the response was not fully read within 30 s of sending the request
java.net.SocketException: Connection reset
Error: read ECONNRESET
EOF
)"
_nn=0
while IFS= read -r _l; do
  [ -n "$_l" ] || continue
  _nn=$((_nn + 1))
  hus_line "$_l"
  assert_eq "1" "$(hus_rc)" "[음성] 제품 쪽 줄을 상류 거절로 판정했다(또는 판정 불가): $_l
$(cat "$_t/out" "$_t/err")"
done <<EOF
$HUS_NEG
EOF
assert_eq "20" "$_nn" "[음성] 음성 줄이 20 개가 아니다 — 목록이 깨졌나?"

# ── 근접 대조군 — **지어낸 줄이다**(실제 로그 줄이 아니다): 실제 양성 줄에서 한 부분만 바꿨다. 처음 다섯은 맥락을 하네스 자신의
#    레지스트리 · 서비스로(그 거절은 우리 인프라 · 게시의 실패다), 다음 둘은 거절 모양을 지웠다(401 은 자격 · 404 는 그 커밋이
#    없다 — 다시 돌려도 같다). 마지막 둘은 서명의 꼬리를 고정한다(PM 변이 프로브 · 리뷰 — 그 전에는 SILENT 였다):
#    · gradle-plugin 의 해석 출처 절(`in any of the following sources`)을 뗀 문구 — 시험 이름 · 요약이 인용하는 꼴이다.
#    · central-absent 의 꼬리표를 리졸버의 다른 로컬 상태로 — `(present, but unavailable)` 은 파일이 로컬 저장소에 **다른 원격에서**
#      와 있다는 뜻이다(maven-resolver-api 1.9.27 `ArtifactResolutionException` 의 문자열 `present` · `, but unavailable` · `absent`).
#      하네스가 스테이징한 BOM(`harness/install/consume/java-app-pom.xml` 의 import)을 central 로 푼 출처 설정 실패다 — 다시 돌려도
#      같다(`java-run.sh` 가 같은 `_remote.repositories` 출처를 단언한다). `(absent)` 는 로컬에 없는 경우만이다.
#    서명이 둘 중 하나만 보게 넓어지면 여기서 운다.
HUS_NEAR="$(cat <<'EOF'
#15 32.80 [ERROR] Non-resolvable import POM: The following artifacts could not be resolved: io.github.xzawed:keycloak-sdk:pom:1.0.0 (absent): Could not transfer artifact io.github.xzawed:keycloak-sdk:pom:1.0.0 from/to mvn-repo (http://mvn-repo/): status code: 429, reason phrase: Too Many Requests (429) @ line 84, column 19
#15 1.930 [ERROR] Non-resolvable import POM: The following artifacts could not be resolved: io.github.xzawed:keycloak-sdk:pom:1.0.0 (absent): Could not find artifact io.github.xzawed:keycloak-sdk:pom:1.0.0 in mvn-repo (http://mvn-repo/) @ line 84, column 19
                > Could not GET 'http://mvn-repo-kotlin/io/github/xzawed/keycloak-sdk-kotlin/1.0.0/keycloak-sdk-kotlin-1.0.0.pom'.
                   > keycloak: Try again
#17 25.83     Failed to download xzawed/keycloak-sdk from dist: The "http://satis-web/dist/xzawed-keycloak-sdk-1.0.0.zip" file could not be downloaded (HTTP/1.1 503 Service Unavailable)
#15 32.80 [ERROR] Non-resolvable import POM: The following artifacts could not be resolved: org.junit:junit-bom:pom:6.1.3 (absent): Could not transfer artifact org.junit:junit-bom:pom:6.1.3 from/to central (https://repo.maven.apache.org/maven2): status code: 401, reason phrase: Unauthorized (401) @ line 84, column 19
#17 25.83     Failed to download psr/clock from dist: The "https://api.github.com/repos/php-fig/clock/zipball/e41a24703d4560fd0acb709162f73b8adfc3aa0d" file could not be downloaded (HTTP/2 404 )
#15 23.70 Plugin [id: 'com.vanniktech.maven.publish', version: '0.37.0'] was not found
#15 1.930 [ERROR] Non-resolvable import POM: The following artifacts could not be resolved: io.github.xzawed:keycloak-sdk-bom:pom:0.1.0 (present, but unavailable): Could not find artifact io.github.xzawed:keycloak-sdk-bom:pom:0.1.0 in central (https://repo.maven.apache.org/maven2) @ line 84, column 19
EOF
)"
_nm=0
while IFS= read -r _l; do
  [ -n "$_l" ] || continue
  _nm=$((_nm + 1))
  hus_line "$_l"
  assert_eq "1" "$(hus_rc)" "[근접] 한 부분만 가진 줄을 상류 거절로 판정했다(또는 판정 불가): $_l
$(cat "$_t/out" "$_t/err")"
done <<EOF
$HUS_NEAR
EOF
assert_eq "9" "$_nm" "[근접] 근접 대조군이 9 개가 아니다 — 목록이 깨졌나?"

# ── gh `--log-failed` 꼴(잡 <TAB> 스텝 <TAB> BOM·시각 본문) — 첫 줄도 끝 줄도 아닌 자리에 묻힌 거절 하나를 찾고, 찍는 줄에는
#    gh 의 칸을 남기지 않는다(첫 줄 · 끝 줄만 보는 판정은 한 줄짜리 양성으로는 안 잡힌다).
cat > "$_t/body.txt" <<'EOF'
Current runner version: '2.338.2'
running (0m06.0s), 10/10 VUs, 429 complete and 0 interrupted iterations
#15 23.70 Plugin [id: 'com.vanniktech.maven.publish', version: '0.37.0'] was not found in any of the following sources:
[2026-09-12 03:13:51] wait_healthy: waiting for http://localhost:9000/health/ready (timeout 240s)
##[error]Process completed with exit code 1.
EOF
awk '{ printf "score-all\tUNKNOWN STEP\t%s2026-11-22T03:%02d:12.2903984Z %s\n", (NR == 1 ? "\357\273\277" : ""), NR, $0 }' \
  "$_t/body.txt" > "$_t/gh.log"
hus "$_t/gh.log"
assert_eq "0" "$(hus_rc)" "[gh 꼴] 셋째 줄의 거절을 놓쳤다: $(cat "$_t/out" "$_t/err")"
assert_contains "$(cat "$_t/out")" "#15 23.70 Plugin [id: 'com.vanniktech.maven.publish', version: '0.37.0'] was not found" \
  "[gh 꼴] 맞은 줄을 찍지 않았다"
assert_not_contains "$(cat "$_t/out")" "UNKNOWN STEP" "[gh 꼴] 찍은 줄에 gh 의 잡 · 스텝 칸이 남았다"
assert_not_contains "$(cat "$_t/out")" "2026-11-22T03:" "[gh 꼴] 찍은 줄에 gh 의 시각 칸이 남았다"
# 같은 로그에서 거절 줄만 빼면 1 이다(위 0 이 그 줄 덕임을 보인다).
grep -v 'Plugin \[id:' "$_t/gh.log" > "$_t/gh-neg.log"
hus "$_t/gh-neg.log"
assert_eq "1" "$(hus_rc)" "[gh 꼴] 거절 줄을 뺀 로그가 1 이 아니다: $(cat "$_t/out" "$_t/err")"

# ── 판정 불가(2) — 「서명 없음」(1)과 갈려야 한다. 만료된 로그(API 410)는 gh 가 아무것도 쓰지 않아 빈 파일로 온다.
#    인자가 둘이면 첫 파일을 판정하지 않는다 — 그래서 첫 파일은 양성이다(무시하고 판정하면 0 이 나와 운다).
printf '%s\n' '                   > plugins-artifacts.gradle.org: Try again' > "$_t/a.log"
: > "$_t/empty.log"
printf '\n   \n\t\n' > "$_t/blank.log"
hus;                              assert_eq "2" "$(hus_rc)" "[판정 불가] 인자 없이 불렀는데 2 가 아니다"
hus "$_t/a.log" "$_t/a.log";      assert_eq "2" "$(hus_rc)" "[판정 불가] 인자가 둘인데 2 가 아니다"
hus "$_t/missing.log";            assert_eq "2" "$(hus_rc)" "[판정 불가] 없는 파일인데 2 가 아니다"
hus "$_t";                        assert_eq "2" "$(hus_rc)" "[판정 불가] 디렉터리인데 2 가 아니다"
hus "$_t/empty.log";              assert_eq "2" "$(hus_rc)" "[판정 불가] 빈 로그(만료 — API 410)를 「서명 없음」으로 넘겼다 — 2 여야 한다"
hus "$_t/blank.log";              assert_eq "2" "$(hus_rc)" "[판정 불가] 공백만 있는 로그인데 2 가 아니다"
# 대조 — 같은 a.log 하나는 0 이다(위 「둘이면 2」가 a.log 의 내용 탓이 아님을 보인다).
hus "$_t/a.log";                  assert_eq "0" "$(hus_rc)" "[판정 불가·대조] 양성 한 줄짜리 로그가 0 이 아니다"

assert_report
