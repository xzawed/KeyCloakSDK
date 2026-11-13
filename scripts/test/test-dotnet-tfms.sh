#!/usr/bin/env sh
# .NET 대상 목록 CLI(`scripts/dotnet-tfms.mjs`) 자가테스트 — dotnet-ci 의 대상 레그 매트릭스가 이 출력에서 나온다.
# 픽스처는 임시 파일뿐이다. 실제 트리의 선언도 한 번 읽어 「매트릭스가 비거나 깨지지 않는다」를 본다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
CLI="$DIR/../dotnet-tfms.mjs"
ROOT="$(cd "$DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
P="$TMP/Directory.Build.props"
rc() { node "$CLI" "$@" >/dev/null 2>&1 && echo 0 || echo $?; }

# 버전 오름차순 — 선언 순서와 문자열 정렬(「net10.0」<「net8.0」) 어느 쪽으로도 갈라진다.
for tfms in 'net10.0;net8.0' 'net8.0;net10.0'; do
  printf '%s\n' "<Project><PropertyGroup><TargetFrameworks>$tfms</TargetFrameworks></PropertyGroup></Project>" > "$P"
  assert_eq '["net8.0","net10.0"]' "$(node "$CLI" "$P")" "버전 오름차순 JSON ($tfms)"
done
printf '%s\n' '<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>' > "$P"
assert_eq '["net8.0"]' "$(node "$CLI" "$P")" '단수 선언도 배열 하나'

# 매트릭스가 비거나 거짓이 되는 입력은 0 이 아니라 2 — 빈 배열로 레그 0 개가 「초록」이 되면 안 된다.
printf '%s\n' '<Project><PropertyGroup></PropertyGroup></Project>' > "$P"
assert_eq 2 "$(rc "$P")" '선언이 없으면 2'
printf '%s\n' '<Project><PropertyGroup><TargetFrameworks>net8.0;netstandard2.0</TargetFrameworks></PropertyGroup></Project>' > "$P"
assert_eq 2 "$(rc "$P")" '모르는 모양이 섞이면 2'
assert_eq 2 "$(rc "$TMP/none.props")" '파일이 없으면 2'

# 실제 트리 — 기본 경로를 저장소 뿌리에서 읽는다(dotnet-ci 가 부르는 그대로).
OUT="$(cd "$ROOT" && node scripts/dotnet-tfms.mjs)"
assert_contains "$OUT" '"net8.0"' '실제 트리의 하한 대상(net8.0)이 목록에 있다'

assert_report
