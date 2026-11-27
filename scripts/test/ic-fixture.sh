#!/usr/bin/env sh
# 통합 전용 커버리지 리포트(`scripts/integration-coverage.mjs`) 자가테스트 셋이 소싱하는 준비 함수 —
# `test-integration-coverage.sh` · `test-integration-coverage-harness.sh` · `test-integration-coverage-unit-owner.sh`. 픽스처와 데이터의 출처(어느 도구가 어떻게 냈는가)는
# `test-integration-coverage.sh` 의 머리가 소유한다.
#
# 부르는 쪽이 먼저 정한다: `DIR`(scripts/test) · `FIX`(픽스처 루트) · `TOOL`(리포트 도구) · `BOUNDARY`(파생 도구).
# ⚠️ 도구 경로를 여기 두지 않는다 — 변이 스윕은 M1 짝(시험 × 그 시험이 실행하는 판정기)을 **시험 파일의 글자**에서
# 파생한다(`scripts/mutation-sweep.mjs` 의 `pairsOf`). 경로가 이 파일에만 있으면 두 시험의 M1 짝이 사라진다.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
T="$TMP/t"
D="$TMP/data"

# 픽스처 트리 + **그 트리의** 파생 도구(실제 `coverage-boundary.mjs` 사본 — 변이가 그대로 전파된다).
fresh() {
  rm -rf "$T" "$D"
  mkdir -p "$T" "$D"
  cp -r "$FIX/tree/." "$T/"
  cp "$BOUNDARY" "$T/scripts/coverage-boundary.mjs"
  cp "$FIX/data/go.cover" "$FIX/data/python.json" "$D/"
  node_data "$FIX/data/node.json"
  rust_data "$FIX/data/rust.lcov"
  php_data "$FIX/data/php"
  ruby_data "$FIX/data/ruby.json"
  dotnet_data "$FIX/data/dotnet.json" "$FIX/data/dotnet.trx"
  java_data "$FIX/data/java.xml"
  kotlin_data "$FIX/data/kotlin.xml"
  git -C "$T" init -q
  git -C "$T" config core.autocrlf false
  git -C "$T" add -A
}
# istanbul 키는 절대 경로다 — 픽스처의 `@ROOT@` 를 이 트리의 경로로(윈도는 `pwd -W` 의 `C:/…` 꼴이 node 가 보는 경로다).
node_data() { # fixture-json
  mkdir -p "$D/node"
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$1" > "$D/node/coverage-final.json"
}
# lcov 의 SF 도 절대 경로다 — 같은 치환(뒤의 `\rust\src\…` 는 리포트가 `/` 로 읽는다).
rust_data() { # fixture-lcov
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$1" > "$D/rust.lcov"
}
# PHPUnit 의 XML 커버리지는 디렉터리다 — 절대 경로는 index.xml 의 `<project source>` 하나다(같은 치환).
php_data() { # fixture-dir
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  rm -rf "$D/php"
  cp -r "$1" "$D/php"
  sed -i "s#@ROOT@#$_r#g" "$D/php/index.xml"
  php_mark 0
}
# `run php` 의 기록(종료코드 · 지금 index.xml 의 sha1)을 쓴다 — run 이 쓰는 것과 같은 꼴. 데이터를 고친 뒤 OK 를 기대하는
# 단언은 이것을 다시 불러야 한다(기록 뒤 바뀐 데이터는 FAIL 이다).
php_mark() { # exit
  printf '{"run":"php","exit":%s,"index_sha1":"%s"}\n' "$1" "$(sha1sum "$D/php/index.xml" | cut -d' ' -f1)" > "$D/php.run.json"
}
# `run ruby` 의 덤프 — 루트와 파일 키가 절대 경로다(Ruby 의 `File.expand_path` — 윈도도 `C:/…`, `/` 구분). 같은 치환 뒤 기록을 쓴다.
ruby_data() { # fixture-json
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$1" > "$D/ruby.json"
  ruby_mark 0
}
# `run ruby` 의 기록(종료코드 · 지금 덤프의 sha1) — php_mark 와 같은 쓰임.
ruby_mark() { # exit
  printf '{"run":"ruby","exit":%s,"dump_sha1":"%s"}\n' "$1" "$(sha1sum "$D/ruby.json" | cut -d' ' -f1)" > "$D/ruby.run.json"
}
# `run dotnet` 의 데이터(coverlet JSON — 문서 키가 절대 경로)와 trx(테스트 어셈블리 경로가 절대 경로) — 같은 치환 뒤 기록을 쓴다.
dotnet_data() { # fixture-json fixture-trx
  _r="$(cd "$T" && { pwd -W 2>/dev/null || pwd; })"
  sed "s#@ROOT@#$_r#g" "$1" > "$D/dotnet.json"
  sed "s#@ROOT@#$_r#g; s#@root@#$_r#g" "$2" > "$D/dotnet.trx"
  dotnet_mark 0
}
# `run dotnet` 의 기록(종료코드 · 데이터와 trx 의 sha1 · 경계 파일의 sha1 — coverlet 데이터에는 해시가 없다) — php_mark 와 같은 쓰임.
dotnet_mark() { # exit
  printf '{"run":"dotnet","exit":%s,"data_sha1":"%s","trx_sha1":"%s","files":{"dotnet/src/Kc/Admin/Client.cs":"%s","dotnet/src/Kc/AuthClient.cs":"%s"}}\n' "$1" \
    "$(sha1sum "$D/dotnet.json" | cut -d' ' -f1)" "$(sha1sum "$D/dotnet.trx" | cut -d' ' -f1)" \
    "$(sha1sum "$T/dotnet/src/Kc/Admin/Client.cs" | cut -d' ' -f1)" "$(sha1sum "$T/dotnet/src/Kc/AuthClient.cs" | cut -d' ' -f1)" > "$D/dotnet.run.json"
}
# `run java` 의 데이터(JaCoCo XML — 경로가 없다)와 javap 의 출력(리포트가 LineNumberTable · EnclosingMethod 를 푼다) — 기록을 쓴다.
java_data() { # fixture-xml
  cp "$1" "$D/java.xml"
  cp "$FIX/data/java.javap.txt" "$D/java.javap.txt"
  java_mark 0
}
# `run java` 의 기록(종료코드 · 데이터와 javap 출력의 sha1 · failsafe 의 테스트 수 · surefire 보고 수 · 경계 파일의 sha1) — php_mark 와 같은 쓰임.
java_mark() { # exit
  printf '{"run":"java","exit":%s,"jacoco":"0.8.16","data_sha1":"%s","javap_sha1":"%s","tests":{"completed":1,"failures":0,"errors":0,"skipped":0},"unit":0,"files":{"java/kc-auth/src/main/java/kc/auth/AuthClient.java":"%s","java/kc-examples/src/main/java/kc/examples/QuickStart.java":"%s"}}\n' "$1" \
    "$(sha1sum "$D/java.xml" | cut -d' ' -f1)" "$(sha1sum "$D/java.javap.txt" | cut -d' ' -f1)" \
    "$(sha1sum "$T/java/kc-auth/src/main/java/kc/auth/AuthClient.java" | cut -d' ' -f1)" "$(sha1sum "$T/java/kc-examples/src/main/java/kc/examples/QuickStart.java" | cut -d' ' -f1)" > "$D/java.run.json"
}
# `run kotlin` 의 데이터(JaCoCo XML)와 javap 의 출력 — 기록을 쓴다(java 와 같은 리더).
kotlin_data() { # fixture-xml
  cp "$1" "$D/kotlin.xml"
  cp "$FIX/data/kotlin.javap.txt" "$D/kotlin.javap.txt"
  kotlin_mark 0
}
# `run kotlin` 의 기록 — java 의 것에 모듈 이름(META-INF/<모듈>.kotlin_module — `internal` 멤버 이름의 접미)이 더해진다.
kotlin_mark() { # exit
  printf '{"run":"kotlin","exit":%s,"jacoco":"0.8.16","module":"kc-kotlin","data_sha1":"%s","javap_sha1":"%s","tests":{"completed":1,"failures":0,"errors":0,"skipped":0},"unit":0,"files":{"kotlin/src/main/kotlin/kc/auth/AuthClient.kt":"%s","kotlin/src/main/kotlin/kc/examples/QuickStart.kt":"%s"}}\n' "$1" \
    "$(sha1sum "$D/kotlin.xml" | cut -d' ' -f1)" "$(sha1sum "$D/kotlin.javap.txt" | cut -d' ' -f1)" \
    "$(sha1sum "$T/kotlin/src/main/kotlin/kc/auth/AuthClient.kt" | cut -d' ' -f1)" "$(sha1sum "$T/kotlin/src/main/kotlin/kc/examples/QuickStart.kt" | cut -d' ' -f1)" > "$D/kotlin.run.json"
}
run() {
  git -C "$T" add -A
  OUT="$(node "$TOOL" "$@" 2>&1)" && RC=0 || RC=$?
}
# 줄 **전체**가 있는가 — 부분문자열 일치는 접미사가 붙은 오판(예: `(package-level …)`)을 통과시킨다.
assert_line() { # output line msg
  if printf '%s\n' "$1" | grep -qxF -- "$2"; then _l=yes; else _l=no; fi
  assert_eq yes "$_l" "$3 — 기대한 줄: [$2]"
}
