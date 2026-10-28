#!/usr/bin/env sh
# CHANGELOG 원장 — check-docs 검사 8d 와 scripts/changelog-rotate.mjs 의 자가테스트.
#
# 겨누는 것: 원장이 다시 상한 없이 자라는 것(2026-10: 한 달에 27 KB → 214 KB), 그리고 회전이
# 내용을 잃거나 바꾸는 것. 보관본 머리는 테스트가 다시 쓰지 않는다 — 회전이 만든 파일을 쓰고,
# 부정 사례는 그 파일을 비틀어 만든다(그래야 테스트가 생성 규칙을 두 번째로 구현하지 않는다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-docs.mjs"
ROT="$DIR/../changelog-rotate.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

big() { head -c "$1" /dev/zero | tr '\0' 'x'; }
# 절 하나: <판> <날짜> <본문 바이트>
sec() { printf '## [%s] - %s (Go)\n\n- %s\n\n' "$1" "$2" "$(big "$3")"; }
# 루트: stdin 의 절들을 [Unreleased] 뒤에 붙인다. UNREL 이 있으면 [Unreleased] 의 본문이 된다.
root_file() {
  { printf '# Changelog\n\n머리말.\n\n## [Unreleased]\n\n'
    [ -n "${UNREL:-}" ] && printf '%s\n' "$UNREL"
    cat; } > "$TMP/CHANGELOG.md"
}
fresh() { rm -rf "$TMP"; mkdir -p "$TMP"; }
run() { node "$GUARD" "$TMP" 2>&1 || true; }
GIT() { git -C "$TMP" -c user.email=t@example.invalid -c user.name=t "$@" >/dev/null 2>&1; }
commit_main() { git init -q -b main "$TMP" >/dev/null 2>&1; GIT add -A; GIT commit -qm base; }

# ---- A. 구조 (git 없음) ----
# A1 정상 — 작은 원장은 통과한다.
fresh; { sec 1.0.2 2026-10-02 10; sec 1.0.1 2026-09-01 10; } | root_file
assert_ok node "$GUARD" "$TMP"

# A2 [Unreleased] 가 없으면 이 저장소 자신에서는 실패, 원장 꼴이 아닌 픽스처는 대상 밖(대조군).
fresh; printf '# Changelog\n\n## [1.0.0] - 2026-08-30\n\n- a\n' > "$TMP/CHANGELOG.md"
_out="$(run)"; assert_not_contains "$_out" "검사 8d" "원장 꼴이 아닌 픽스처는 8d 대상이 아니다"
mkdir -p "$TMP/scripts"; : > "$TMP/scripts/check-docs.mjs"
_out="$(run)"; assert_contains "$_out" '`## [Unreleased]` 가 0개다' "저장소 자신에서는 [Unreleased] 를 지워 8d 를 끌 수 없다"

# A3 모르는 ## 제목.
fresh; { printf '## 메모\n\n본문\n\n'; sec 1.0.1 2026-09-01 10; } | root_file
_out="$(run)"; assert_contains "$_out" "원장의 ## 제목은" "릴리스 절이 아닌 ## 제목을 지목한다"

# A4 순서 — 오래된 날짜가 앞에 오면 실패.
fresh; { sec 1.0.1 2026-09-01 10; sec 1.0.2 2026-10-02 10; } | root_file
_out="$(run)"; assert_contains "$_out" "원장은 최신순이다" "날짜 역전을 지목한다"

# A5 루트 상한 — 날짜가 둘 이상이면 실패, 날짜 하나뿐이면 통과(날짜는 쪼개지 않는다).
fresh; { sec 1.0.2 2026-10-02 40000; sec 1.0.1 2026-09-01 40000; } | root_file
_out="$(run)"; assert_contains "$_out" "원장 루트 상한 65536B" "상한 초과를 지목한다"
assert_contains "$_out" "node scripts/changelog-rotate.mjs" "나가는 길(회전 명령)을 인쇄한다"
fresh; { sec 1.0.3 2026-10-02 40000; sec 1.0.2 2026-10-02 40000; } | root_file
_out="$(run)"; assert_not_contains "$_out" "원장 루트 상한" "날짜 하나가 혼자 넘는 것은 허용한다(대조군)"
# 경계 — 정확히 65,536B 는 통과하고 1 바이트 넘으면 실패한다(상한이 실제로 그 수임을 고정한다).
fresh; { sec 1.0.2 2026-10-02 30000; sec 1.0.1 2026-09-01 30000; } | root_file
_pad=$((65536 - $(wc -c < "$TMP/CHANGELOG.md")))
fresh; { sec 1.0.2 2026-10-02 $((30000 + _pad)); sec 1.0.1 2026-09-01 30000; } | root_file
assert_eq 65536 "$(wc -c < "$TMP/CHANGELOG.md" | tr -d ' ')" "경계 픽스처가 정확히 65,536B 다"
_out="$(run)"; assert_not_contains "$_out" "원장 루트 상한" "정확히 상한이면 통과한다"
printf 'x' >> "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "65537B > 원장 루트 상한" "1 바이트 넘으면 실패한다"

# A6 [Unreleased] 항목 상한 — 경계 1024B 통과, 1025B 실패, 들여쓴 이어짐 줄도 센다.
fresh; UNREL="- $(big 1021)"; : | root_file; unset UNREL
assert_ok node "$GUARD" "$TMP"
fresh; UNREL="- $(big 1022)"; : | root_file; unset UNREL
_out="$(run)"; assert_contains "$_out" "항목 1025B > 1024B" "1025B 항목을 지목한다"
fresh; UNREL="$(printf -- '- %s\n  %s' "$(big 500)" "$(big 521)")"; : | root_file; unset UNREL
_out="$(run)"; assert_contains "$_out" "항목 1027B > 1024B" "이어지는 줄까지 한 항목으로 센다"
# A7 상한을 피해 가는 세 모양 — `* ` 표지 · 들여쓰지 않은 「게으른 이어짐」 · 표지 없는 문단.
fresh; UNREL="* $(big 1022)"; : | root_file; unset UNREL
_out="$(run)"; assert_contains "$_out" "항목 1025B > 1024B" "\`* \` 표지도 항목이다"
fresh; UNREL="$(printf -- '- short\n%s' "$(big 1100)")"; : | root_file; unset UNREL
_out="$(run)"; assert_contains "$_out" "항목 1109B > 1024B" "들여쓰지 않은 이어짐 줄도 그 항목에 센다"
fresh; UNREL="$(big 1024)"; : | root_file; unset UNREL
_out="$(run)"; assert_contains "$_out" "항목 1025B > 1024B" "[Unreleased] 의 표지 없는 문단도 항목이다"

# ---- C. 회전 ----
# C1 상한 안이면 아무것도 하지 않는다.
fresh; { sec 1.0.2 2026-10-02 10; } | root_file
_before="$(cksum < "$TMP/CHANGELOG.md")"
_o="$(node "$ROT" --root="$TMP" 2>&1)"; assert_contains "$_o" "옮길 것이 없다" "상한 안이면 그대로 둔다"
assert_eq "$_before" "$(cksum < "$TMP/CHANGELOG.md")" "그대로 둘 때 루트가 한 바이트도 안 바뀐다"
assert_eq "no" "$([ -d "$TMP/changelog" ] && echo yes || echo no)" "보관본 디렉터리를 만들지 않는다"

# C2 상한 초과 — 가장 오래된 날짜부터 옮기고, 결과는 8d 를 통과하고, 두 번째 실행은 무동작이다.
# 크기: 21,000B 절 다섯 ≈ 105 KB. 가장 오래된 08-30 을 옮겨도 84 KB(> 64 KiB)라 09-10 까지 옮기고,
# 거기서 63 KB 라 멈춘다 — 정확히 두 날짜가 움직여야 한다.
rot_fix() {
  fresh
  { sec 1.0.5 2026-10-20 21000; sec 1.0.4 2026-10-10 21000; sec 1.0.3 2026-09-20 21000
    printf '## [1.0.2] - 2026-09-10 (Go)\n\n- 링크 [안내](docs/guide.md) 와 [규칙](CLAUDE.md).\n- %s\n\n' "$(big 21000)"
    sec 1.0.1 2026-08-30 21000; } | root_file
  mkdir -p "$TMP/docs"; printf '# g\n' > "$TMP/docs/guide.md"; printf '# c\n' > "$TMP/CLAUDE.md"
}
rot_fix; commit_main
_o="$(node "$ROT" --root="$TMP" 2>&1)"
assert_contains "$_o" "2026-09-10 · 2026-08-30" "가장 오래된 두 날짜를 옮긴다"
assert_eq "yes yes" "$([ -f "$TMP/changelog/2026-09.md" ] && echo yes) $([ -f "$TMP/changelog/2026-08.md" ] && echo yes)" "달마다 보관본을 만든다"
assert_contains "$(cat "$TMP/CHANGELOG.md")" "> 이전 릴리스(월별 보관본): [2026-09](changelog/2026-09.md) · [2026-08](changelog/2026-08.md)" "루트에 색인 줄을 단다"
assert_contains "$(cat "$TMP/changelog/2026-09.md")" "](../docs/guide.md)" "상대 링크를 한 단계 위로 고친다"
assert_contains "$(cat "$TMP/changelog/2026-09.md")" "](../CLAUDE.md)" "맨 이름 링크도 고친다"
_out="$(run)"; assert_not_contains "$_out" "검사 8d" "회전 결과는 8d(보존 포함)를 통과한다"
_c1="$(cat "$TMP/CHANGELOG.md" "$TMP/changelog/"*.md | cksum)"
_o="$(node "$ROT" --root="$TMP" 2>&1)"; assert_contains "$_o" "옮길 것이 없다" "두 번째 실행은 무동작이다"
assert_eq "$_c1" "$(cat "$TMP/CHANGELOG.md" "$TMP/changelog/"*.md | cksum)" "두 번째 실행이 원장을 바꾸지 않는다"

# C3 보관본 형식이 깨져 있으면 회전은 손대지 않는다 — 루트를 다시 상한 위로 올려도 아무것도 쓰지 않는다.
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('# Changelog — 2026-08','# 메모'))" "$TMP/changelog/2026-08.md"
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [Unreleased]\n\n','## [Unreleased]\n\n## [1.0.9] - 2026-10-28 (Go)\n\n- '+'x'.repeat(30000)+'\n\n'))" "$TMP/CHANGELOG.md"
_before="$(cat "$TMP/CHANGELOG.md" "$TMP/changelog/"*.md | cksum)"
_o="$(node "$ROT" --root="$TMP" 2>&1 || true)"; assert_contains "$_o" "보관본 형식이 아니다" "깨진 보관본을 지목한다"
assert_eq "$_before" "$(cat "$TMP/CHANGELOG.md" "$TMP/changelog/"*.md | cksum)" "멈출 때 원장을 한 바이트도 쓰지 않는다"

# ---- B. 보존 (git 기준 = main 과의 merge-base) ----
# 회전된 원장을 기준으로 커밋해 두고 한 가지씩만 비튼다.
rot_base() { rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1; commit_main; }

# B1 대조군 — 변화 없음은 통과한다.
rot_base; _out="$(run)"; assert_not_contains "$_out" "검사 8d" "기준과 같으면 통과한다"

# B2 루트의 절을 지우면 실패.
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace(/## \[1\.0\.4\][^]*?(?=## \[1\.0\.3\])/,''))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "「## [1.0.4] - 2026-10-10 (Go)」 이 사라졌다" "지운 절을 지목한다"

# B3 보관본의 절을 고치면 실패.
rot_base; printf 'x\n' >> "$TMP/changelog/2026-08.md"
_out="$(run)"; assert_contains "$_out" "보관본은 고치지 않는다" "보관본 수정을 지목한다"

# B4 기준에 없던 절을 보관본에 바로 쓰면 실패.
rot_base; printf '## [0.9.0] - 2026-08-01 (Go)\n\n- 새것\n\n' >> "$TMP/changelog/2026-08.md"
_out="$(run)"; assert_contains "$_out" "기준에 없던 절인데 보관본에 있다" "보관본 직접 기입을 지목한다"

# B5 옮기면서 고치면 실패 — 기준(회전 전)에서 회전한 뒤 옮긴 절 하나에 한 바이트를 더한다.
rot_fix; commit_main; node "$ROT" --root="$TMP" >/dev/null 2>&1
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('규칙](../CLAUDE.md).','규칙](../CLAUDE.md)!'))" "$TMP/changelog/2026-09.md"
_out="$(run)"; assert_contains "$_out" "옮기면서 내용이 바뀌었다" "옮기며 고친 것을 지목한다"

# B6 기준에 없던 새 루트 절(범프)의 항목도 상한을 받는다 — 우회 차단. 짧으면 통과(대조군).
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [Unreleased]\n\n','## [Unreleased]\n\n## [1.0.6] - 2026-10-27 (Go)\n\n- '+'x'.repeat(1100)+'\n\n'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "「## [1.0.6] - 2026-10-27 (Go)」: 항목 1103B > 1024B" "새 절의 긴 항목을 지목한다"
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [Unreleased]\n\n','## [Unreleased]\n\n## [1.0.6] - 2026-10-27 (Go)\n\n- 짧다\n\n'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_not_contains "$_out" "검사 8d" "새 절의 짧은 항목은 통과한다"
# 새 절의 물결 머리말 문단도 항목이다 — 범프가 긴 서사를 머리말로 쓰면 상한을 피해 갔다(PM 2 차 패스).
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [Unreleased]\n\n','## [Unreleased]\n\n## [1.0.6] - 2026-10-27 (Go)\n\n**'+'y'.repeat(1100)+'**\n\n- 짧다\n\n'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "항목 1105B > 1024B" "새 절의 긴 머리말 문단을 지목한다"
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [Unreleased]\n\n','## [Unreleased]\n\n## [1.0.6] - 2026-10-27 (Go)\n\n**'+'y'.repeat(900)+'**\n\n- 짧다\n\n'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_not_contains "$_out" "검사 8d" "새 절의 짧은 머리말 문단은 통과한다(대조군)"

# B7 낡은 브랜치 — main 이 새 절을 얻은 뒤에도, 갈라진 브랜치에는 거짓 「사라졌다」가 없다.
rot_base
GIT checkout -q -b topic
GIT checkout -q main
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [Unreleased]\n\n','## [Unreleased]\n\n## [1.0.6] - 2026-10-27 (Go)\n\n- 짧다\n\n'))" "$TMP/CHANGELOG.md"
GIT commit -qam main-moved
GIT checkout -q topic
_out="$(run)"; assert_not_contains "$_out" "사라졌다" "merge-base 기준이라 낡은 브랜치에 거짓 빨강이 없다"

# B8 공허 방지 — 저장소 자신인데 main 기준이 없으면 실패. git 이 아니면 그 오류가 없다(대조군).
rot_base; mkdir -p "$TMP/scripts"; : > "$TMP/scripts/check-docs.mjs"; GIT add -A; GIT commit -qm stub
GIT branch -m main other
_out="$(run)"; assert_contains "$_out" "원장 보존 검사가 공허하다" "기준 부재를 공허로 지목한다"
rm -rf "$TMP/.git"
_out="$(run)"; assert_not_contains "$_out" "원장 보존 검사가 공허하다" "git 밖에서는 보존 검사를 하지 않는다"

# ---- G. 독립 레그(Grok)가 낸 주장 — 하나씩 재현해 RED 로 고정한 것 ----
# G1 저장소 자신에서 원장 파일이 통째로 없으면 실패다(존재하지 않으면 「대상 아님」으로 조용했다).
fresh; mkdir -p "$TMP/scripts"; : > "$TMP/scripts/check-docs.mjs"
_out="$(run)"; assert_contains "$_out" "원장(CHANGELOG.md)이 없다" "원장을 지워 8d 를 끌 수 없다"
# G2 저장소 자신에서 기준에 원장이 없으면(읽기 실패 포함) 「새 원장」으로 넘기지 않는다.
fresh; mkdir -p "$TMP/scripts"; : > "$TMP/scripts/check-docs.mjs"; printf 'x\n' > "$TMP/x.txt"; commit_main
{ sec 1.0.1 2026-09-01 10; } | root_file
_out="$(run)"; assert_contains "$_out" "기준(main)에서 원장을 읽지 못했다" "기준의 원장 부재를 「새 원장」으로 넘기지 않는다"
# G3 이미 있는 루트 절에 긴 항목을 덧붙여 상한을 피하지 못한다 — 그 절이 기준 대비 1,024B 넘게 자라면 실패.
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [1.0.5] - 2026-10-20 (Go)\n\n','## [1.0.5] - 2026-10-20 (Go)\n\n- '+'z'.repeat(1100)+'\n'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "「## [1.0.5] - 2026-10-20 (Go)」 이 기준보다 1103B 자랐다" "기존 절에 덧붙인 긴 항목을 지목한다"
# 대조군 — 기존 절의 오탈자 수정(크기 그대로)은 통과한다.
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [1.0.5] - 2026-10-20 (Go)\n\n- x','## [1.0.5] - 2026-10-20 (Go)\n\n- y'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_not_contains "$_out" "검사 8d" "기존 절의 같은 크기 수정은 통과한다"
# G4 기준에 이미 있던 [Unreleased] 항목은 그 자체로 다른 PR 을 막지 않는다(차분 기준).
fresh; UNREL="- $(big 2000)"; { sec 1.0.1 2026-09-01 10; } | root_file; unset UNREL; commit_main
printf 'readme\n' > "$TMP/README.txt"
_out="$(run)"; assert_not_contains "$_out" "항목 2003B" "기준과 같은 [Unreleased] 항목은 무관한 PR 을 막지 않는다"
# 대조군 — 그 항목을 고치면(새 글이 되면) 상한을 받는다.
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('- x','- w'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "항목 2003B > 1024B" "고친 [Unreleased] 항목은 상한을 받는다"
# G5 CRLF 로 체크아웃된 원장도 같은 원장이다(읽을 때 줄 끝을 맞춘다) — 이 저장소는 *.md eol=lf 라
#    실제로는 안 생기지만, 체크아웃 설정 하나로 거짓 빨강이 나서는 안 된다.
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1
for _f in "$TMP/CHANGELOG.md" "$TMP/changelog/"*.md; do sed -i 's/$/\r/' "$_f"; done
_out="$(run)"; assert_not_contains "$_out" "검사 8d" "CRLF 원장도 통과한다"

# G6 루트 머리말에 긴 글을 덧붙여 상한을 피하지 못한다 — 색인 줄을 뺀 머리말이 기준보다 1,024B 넘게 자라면 실패(PM 2 차 패스).
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('머리말.\n','머리말.\n\n'+'q'.repeat(1100)+'\n'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "머리말이 기준보다 1102B 자랐다" "머리말에 덧붙인 긴 글을 지목한다"
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('머리말.','머리글.'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_not_contains "$_out" "검사 8d" "머리말의 작은 고침은 통과한다(대조군)"

# ---- H. 독립 레그 2 차 — 하나씩 재현해 RED 로 고정한 것 ----
# H1 보관본 링크의 `../` 를 지우는 고침도 「고침」이다(정규화하면 같아 보였다).
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('](../docs/guide.md)','](docs/guide.md)'))" "$TMP/changelog/2026-09.md"
_out="$(run)"; assert_contains "$_out" "보관본은 고치지 않는다" "보관본 링크의 ../ 제거를 지목한다"
# H2 옮기면서 링크를 회전기가 만들 꼴과 다르게 쓰면 실패(정규화로는 같아 보였다).
rot_fix; commit_main; node "$ROT" --root="$TMP" >/dev/null 2>&1
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('](../CLAUDE.md)','](CLAUDE.md)'))" "$TMP/changelog/2026-09.md"
_out="$(run)"; assert_contains "$_out" "옮기면서 내용이 바뀌었다" "옮기며 링크를 회전기와 다르게 쓴 것을 지목한다"
# H3 기준에 같은 제목이 둘이면 보존 대조가 하나를 잃는다 — 실패로 닫는다.
fresh; { sec 1.0.1 2026-09-01 10; sec 1.0.1 2026-09-01 20; } | root_file; commit_main
_out="$(run)"; assert_contains "$_out" "기준에 같은 제목이 둘 이상 있다" "기준의 중복 제목을 지목한다"
# H4 회전으로 줄일 수 없는 초과 — 머리말+[Unreleased] 만으로 상한을 넘으면 날짜가 없어도·하나여도 실패.
fresh; UNREL="$(_i=0; while [ "$_i" -lt 70 ]; do printf -- '- %s\n' "$(big 1000)"; _i=$((_i + 1)); done)"; : | root_file; unset UNREL
_out="$(run)"; assert_contains "$_out" "회전으로 줄일 수 없다" "날짜 없는 루트의 [Unreleased] 초과를 지목한다"
fresh; UNREL="$(_i=0; while [ "$_i" -lt 70 ]; do printf -- '- %s\n' "$(big 1000)"; _i=$((_i + 1)); done)"; { sec 1.0.1 2026-09-01 10; } | root_file; unset UNREL
_out="$(run)"; assert_contains "$_out" "회전으로 줄일 수 없다" "날짜 하나뿐이어도 [Unreleased] 초과는 지목한다"
# H5 제목 줄에 긴 글을 숨기지 못한다 — [Unreleased] 의 소제목, 새 절의 제목 줄.
fresh; UNREL="### $(big 1100)"; : | root_file; unset UNREL
_out="$(run)"; assert_contains "$_out" "항목 1105B > 1024B" "[Unreleased] 의 긴 소제목을 지목한다"
rot_base
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('## [Unreleased]\n\n','## [Unreleased]\n\n## [1.0.6] - 2026-10-27 (Go) '+'h'.repeat(1100)+'\n\n- 짧다\n\n'))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "항목 1130B > 1024B" "새 절의 긴 제목 줄을 지목한다"
# H6 기준 [Unreleased] 에 그대로 있던 항목은 범프가 새 절로 옮겨도 다시 재지 않는다(거짓 빨강 방지).
fresh; UNREL="- $(big 2000)"; { sec 1.0.1 2026-09-01 10; } | root_file; unset UNREL; commit_main
node -e "const f=process.argv[1],fs=require('fs');const t=fs.readFileSync(f,'utf8');const m=t.match(/## \[Unreleased\]\n\n(- x+\n)/);fs.writeFileSync(f,t.replace(m[0],'## [Unreleased]\n\n## [1.0.2] - 2026-10-02 (Go)\n\n**머리말**\n\n'+m[1]))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_not_contains "$_out" "검사 8d" "기준의 [Unreleased] 항목을 옮긴 범프는 통과한다"
# H7 표지가 다른 항목 둘은 두 항목이다 — 나누지 못하면 둘이 합쳐져 거짓 빨강이 난다(변이 L10 이 여기서 SILENT 였다).
fresh; UNREL="$(printf -- '- %s\n* %s' "$(big 600)" "$(big 600)")"; : | root_file; unset UNREL
assert_ok node "$GUARD" "$TMP"

# ---- 구조: 회전된 보관본을 비튼다 ----
# S1 보관본 머리 변조.
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('# Changelog — 2026-08','# 메모'))" "$TMP/changelog/2026-08.md"
_out="$(run)"; assert_contains "$_out" "머리가 생성된 형식과 다르다" "보관본 머리 변조를 지목한다"
# S2 다른 달의 절.
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('2026-08-30','2026-07-30'))" "$TMP/changelog/2026-08.md"
_out="$(run)"; assert_contains "$_out" "보관본은 그 달의 절만 담는다" "달이 다른 절을 지목한다"
# S3 보관본 날짜가 루트보다 새것.
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('2026-09-10','2026-09-25'))" "$TMP/changelog/2026-09.md"
_out="$(run)"; assert_contains "$_out" "날짜 하나는 한 곳에만 산다" "루트보다 새 보관본 날짜를 지목한다"
# S3b 경계 — 루트의 가장 오래된 날짜(09-20)와 **같은** 날짜가 보관본에 있어도 실패다(날짜는 한 곳에만).
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace('2026-09-10','2026-09-20'))" "$TMP/changelog/2026-09.md"
_out="$(run)"; assert_contains "$_out" "날짜 하나는 한 곳에만 산다" "루트와 같은 날짜가 보관본에 있는 것도 지목한다"
# S4 같은 절이 두 곳에.
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1
sec 1.0.1 2026-08-30 10 >> "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "절 하나는 한 곳에만 산다" "중복 절을 지목한다"
# S5 색인 줄이 실제와 다르다 / 보관본 없이 색인만 있다.
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1
node -e "const f=process.argv[1],fs=require('fs');fs.writeFileSync(f,fs.readFileSync(f,'utf8').replace(' · [2026-08](changelog/2026-08.md)',''))" "$TMP/CHANGELOG.md"
_out="$(run)"; assert_contains "$_out" "보관본 색인 줄이 실제 보관본과 다르다" "색인 누락을 지목한다"
rm -rf "$TMP/changelog"
_out="$(run)"; assert_contains "$_out" "보관본이 없는데 색인 줄이 있다" "남은 색인을 지목한다"
# S6 changelog/ 에 보관본 아닌 파일.
rot_fix; node "$ROT" --root="$TMP" >/dev/null 2>&1; printf '# n\n' > "$TMP/changelog/notes.md"
_out="$(run)"; assert_contains "$_out" "월별 보관본(<YYYY-MM>.md)만 둔다" "보관본 아닌 파일을 지목한다"

assert_report
