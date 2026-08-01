#!/usr/bin/env sh
# 릴리스 프리릴리스 판정 자가테스트.
#
# 왜 이 파일이 있는가: `php-v0.1.0-rc.1`의 첫 실행에서 파이프라인 다섯 잡이 전부 green이었는데도
# GitHub Release가 `prerelease=false`로 만들어져 RC가 저장소의 **Latest release**로 걸렸다.
# 파이프라인 성공은 이 결함을 잡지 못한다 — 태그를 태우지 않고 검증할 수 있는 것은 **판정 로직**뿐이다.
#
# 그래서 이 테스트는 워크플로에서 판정 블록을 **그대로 떼어내** 실행한다. 복사본을 두고 테스트하면
# 워크플로만 고쳤을 때 조용히 통과한다 — 검증 대상은 실제로 배포되는 그 문자열이어야 한다.
#
# 검사하는 것:
#   (1) `gh release create`를 부르는 워크플로 집합 == 판정 블록을 가진 워크플로 집합 (양방향)
#   (2) 세 블록이 글자 그대로 동일 (한 곳만 고치는 드리프트 차단)
#   (3) 판정 결과가 `--prerelease=`로 실제 배선됨 (판정만 하고 안 쓰는 사고 차단)
#   (4) 분류표 — 아홉 언어의 표기 + 오탐 대조군
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
WF="$(cd "$DIR/../.." && pwd)/.github/workflows"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 마커 사이만 뽑고 워크플로 들여쓰기(`run: |` 안 10칸)를 벗긴다. `{10}` 반복 표기는 mawk에서
# 기본 비활성이라 리터럴 공백 10칸으로 적는다(ubuntu 러너의 기본 awk가 mawk다).
extract() {
  awk '
    /# <<< prerelease-classify/ { inb = 0 }
    inb                         { sub(/^          /, ""); print }
    /# >>> prerelease-classify/ { inb = 1 }
  ' "$1"
}

# ── (1) 호출자 집합 == 블록 보유자 집합 ────────────────────────────────────────
# 한 방향만 보면 새 릴리스 워크플로가 판정 없이 추가돼도 통과한다. 반대 방향은 블록만 남고
# 호출부가 사라진(= 죽은 코드) 상태를 잡는다. 두 목록을 문자열로 고정하면 둘 다 걸린다.
# 패턴에 여는 따옴표를 포함한다 — 이 워크플로들의 `permissions:` 근거 주석이 `` `gh release create` ``를
# 그대로 인용하고 있어서, 따옴표 없이 grep하면 호출부와 주석을 구분하지 못한다.
callers="$(grep -rl 'gh release create "' "$WF" | sort)"
marked="$(grep -rl '>>> prerelease-classify' "$WF" | sort)"
assert_eq "$callers" "$marked" "GitHub Release를 만드는 워크플로와 프리릴리스 판정을 가진 워크플로가 정확히 같은 집합이다"
assert_eq "3" "$(printf '%s\n' "$callers" | wc -l | tr -d ' ')" "Release를 만드는 워크플로는 셋(go·dotnet·php)이다"

# ── (2) 세 블록이 글자 그대로 동일 ────────────────────────────────────────────
first=''
for f in $callers; do
  base="$(basename "$f")"
  extract "$f" >"$TMP/$base.block"
  assert_ok test -s "$TMP/$base.block"
  if [ -z "$first" ]; then
    first="$TMP/$base.block"
  else
    assert_ok cmp -s "$first" "$TMP/$base.block"
  fi
done
cp "$first" "$TMP/classify.sh"
# 블록이 실제로 판정을 **한다**는 것도 고정한다 — 마커만 남기고 본문을 지워도 (1)(2)는 통과한다.
assert_contains "$(cat "$TMP/classify.sh")" 'PRERELEASE=true' "블록이 판정 본문을 담고 있다"
assert_contains "$(cat "$TMP/classify.sh")" 'CORE="${VERSION%%+*}"' "블록이 빌드 메타데이터를 떼어낸다(오탐 방지선)"

# ── (3) 판정이 gh로 배선됐는가 ────────────────────────────────────────────────
# 판정만 하고 `gh release create`에 안 넘기면 버그는 그대로다. 세 파일 각각에서 확인한다.
for f in $callers; do
  base="$(basename "$f")"
  assert_contains "$(cat "$f")" 'prerelease: ${{ steps.derive.outputs.prerelease }}' "$base: version 잡이 판정을 출력한다"
  assert_contains "$(cat "$f")" 'PRERELEASE: ${{ needs.version.outputs.prerelease }}' "$base: 릴리스 잡이 그 출력을 받는다"
  assert_contains "$(cat "$f")" '--prerelease="${PRERELEASE}"' "$base: gh release create에 실제로 넘긴다"
done

# ── (4) 분류표 ────────────────────────────────────────────────────────────────
# 워크플로에서 떼어낸 블록을 그대로 실행한다. 판정 불가는 exit 1이므로 UNDECIDABLE로 접는다.
# ⚠️ 블록의 출력은 **stdout으로** 버린다 — `::error::`는 GitHub 워크플로 명령이라 stderr가 아니라
# stdout으로 나간다(2>/dev/null만 걸면 진단 문구가 판정값에 섞여 들어온다).
classify() {
  (
    VERSION="$1"
    . "$TMP/classify.sh" >/dev/null 2>&1
    printf '%s' "$PRERELEASE"
  ) || printf 'UNDECIDABLE'
}

# 왼쪽이 입력, 오른쪽이 기대값. 각 행이 지키는 것:
#   1.0.0+incompatible  — 빌드 메타데이터 제거선. 이 행 없이는 정식 go 버전이 프리릴리스로 샌다(오탐).
#   1.2.3.4             — NuGet 4마디. "숫자 마디 = 정식"이 3마디로 좁혀지면 여기서 걸린다.
#   1.0.0-1             — 알파벳 없는 SemVer 프리릴리스. 하이픈 규칙을 지우면 UNDECIDABLE이 된다.
#   0.1.0rc1/0.1.0.rc1  — PEP 440·RubyGems 표기. go/dotnet/php로는 올 수 없지만, 이 판정이
#                         python/ruby로 확장돼도 조용히 틀리지 않는다는 계약이다.
#   1.0.0_1             — 모르는 표기. fail-closed가 살아 있는지 본다(else를 false로 바꾸면 빨개진다).
ROWS='0.1.0=false
1.0.0=false
0.10.0=false
1.2.3.4=false
1.0.0+incompatible=false
0.1.0-rc.1=true
0.1.0-RC1=true
0.1.0rc1=true
0.1.0.rc1=true
0.1.0-SNAPSHOT=true
0.1.0-alpha.2=true
1.0.0-1=true
0.1.0-rc.1+build.7=true
1.0.0_1=UNDECIDABLE
=UNDECIDABLE'

printf '\n%-24s %-12s %s\n' 'VERSION' 'EXPECTED' 'ACTUAL'
rows=0
printf '%s\n' "$ROWS" | while IFS= read -r row; do
  v="${row%=*}"
  want="${row##*=}"
  got="$(classify "$v")"
  printf '%-24s %-12s %s\n' "${v:-(empty)}" "$want" "$got"
done
# 위 while은 파이프라인이라 서브셸에서 돌아 카운터가 새지 않는다 — 단언은 여기서 다시 돈다.
for row in $ROWS; do
  v="${row%=*}"
  want="${row##*=}"
  assert_eq "$want" "$(classify "$v")" "분류: '${v:-(empty)}'"
  rows=$((rows + 1))
done
# 표가 조용히 비면(변수명을 잘못 고치는 등) 위 루프는 0회 돌고 통과한다. 행수를 못박는다.
assert_eq "15" "$rows" "분류표 행수(줄이는 변경은 곧 커버리지 축소다)"

assert_report
