#!/usr/bin/env sh
# dispatch-release.yml 자가테스트 — YAML 안에 남은 검증 로직을 고정한다.
#
# 왜 이 파일이 있는가: 릴리스 요청 검증은 scripts/release-request.sh로 분리돼 테스트를 갖지만,
# **워크플로 YAML 안에 남은 것들**은 무검증이었다 — 그리고 거기에 결함이 있었다.
# 매니페스트 대조가 `php` 리터럴 하나만 면제해서 **java는 모든 릴리스가**(POM이 설계대로
# `-SNAPSHOT`이라 어떤 값도 대조를 만족할 수 없다) **dotnet은 `0.1.0` 외 모든 버전이**
# "버전 범프가 반쯤 적용됐다"는 거짓 진단으로 중단됐다. 아홉 언어를 한 번씩 통과시켜 봤다면
# 첫날 보였을 것이다.
#
# ⚠️ 검증 대상은 **실제로 배포되는 그 문자열**이어야 한다(test-release-prerelease.sh가 세운
# 관용). 로직을 이 파일에 복사해두면 워크플로만 고쳤을 때 조용히 통과한다. 그래서 워크플로에서
# 마커(`# >>> dispatch-*` … `# <<< dispatch-*`) 사이를 그대로 떼어내 실행한다.
#
# ⚠️ 환경 의존 어서션을 쓰지 않는다. 매니페스트 버전은 하드코딩하지 않고 이 저장소의 추출
# SSOT(`check-versions.mjs --list`)에서 읽는다 — 누가 버전을 범프해도 이 테스트는 뒤집히지
# 않는다(test-deploy-md.sh·test-release-readiness.sh가 두 번 겪은 부류다).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
WF="$ROOT/.github/workflows/dispatch-release.yml"
. "$ROOT/scripts/lib/deploy-facts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 마커 사이만 뽑고 워크플로 들여쓰기(`run: |` 안 10칸)를 벗긴다. `{10}` 반복 표기는 mawk에서
# 기본 비활성이라 리터럴 공백 10칸으로 적는다(우분투 러너의 기본 awk가 mawk다).
#
# ⚠️ `\r`도 떼어낸다. `.gitattributes`는 `*.sh`·`*.md`만 `eol=lf`로 고정하고 `*.yml`은 고정하지
# 않으므로, Windows 기본(`core.autocrlf=true`) 체크아웃에서 워크플로는 **CRLF**로 내려온다.
# 그대로 떼어내면 `case … in\r`이 `Syntax error: word unexpected (expecting "in")`으로 죽어서,
# 이 테스트가 **CI에서만** 돌릴 수 있는 것이 된다 — C4가 정확히 그 부류의 사고였다.
extract() { # <마커명> → stdout: 블록 본문
  awk -v m="$1" '
    index($0, "# <<< " m) { inb = 0 }
    inb                   { sub(/\r$/, ""); sub(/^          /, ""); print }
    index($0, "# >>> " m) { inb = 1 }
  ' "$WF"
}

for m in dispatch-refguard dispatch-manifest dispatch-tagguard; do
  extract "$m" > "$TMP/$m.sh"
  # 블록이 사라지거나 마커 이름이 바뀌면 여기서 멈춘다 — 빈 블록은 "sh가 아무것도 안 하고
  # 0으로 끝남"이라 아래 assert_ok를 전부 통과시킨다(공허한 통과).
  assert_ok test -s "$TMP/$m.sh"
done

run_refguard()  { ( GITHUB_REF="$1" EVENT_NAME=test sh "$TMP/dispatch-refguard.sh" ); }
run_manifest()  { ( cd "$ROOT" && LANG_="$1" VERSION="$2" sh "$TMP/dispatch-manifest.sh" ); }
run_tagguard()  { ( TAG="$1" sh "$TMP/dispatch-tagguard.sh" ); }

# ── (1) ref 가드 — 머지 없이 임의 브랜치에서 릴리스가 나가는 경로를 막는다 ─────
# workflow_dispatch는 **선택된 ref의 워크플로 정의**로 실행되고 checkout도 그 ref를 가져온다.
# 시크릿은 브랜치로 스코프되지 않으므로, 가드가 없으면 브랜치 하나를 밀고 dispatch하는 것만으로
# PR diff도 머지도 사람 승인도 없이 그 브랜치의 코드가 레지스트리에 나간다.
assert_ok    run_refguard refs/heads/main
assert_fails run_refguard refs/heads/attacker-branch
assert_fails run_refguard refs/heads/mainline          # 접두 일치로 새지 않는다
assert_fails run_refguard refs/tags/py-v9.9.9
assert_fails run_refguard refs/pull/1/merge
assert_fails run_refguard ''
# 가드는 체크아웃보다 **앞**에 있어야 한다 — 뒤에 두면 공격자 ref의 트리를 이미 받은 뒤다.
rg_line="$(grep -n 'dispatch-refguard' "$WF" | head -1 | cut -d: -f1)"
co_line="$(grep -n 'actions/checkout@' "$WF" | head -1 | cut -d: -f1)"
assert_ok test "$rg_line" -lt "$co_line"
# 트리 자체를 보는 두 번째 방어선(체크아웃된 커밋이 main 선상인가)도 있어야 한다.
assert_contains "$(cat "$WF")" 'merge-base --is-ancestor' "체크아웃된 커밋이 main의 조상인지 확인한다"

# ── (2) 매니페스트 대조 — 아홉 언어가 전부 통과 **가능한가** ──────────────────
# 자동범프 4종(go·php·dotnet·java)은 태그가 버전 SSOT라 대조 대상이 아니다. 면제를 리터럴로
# 적으면(과거 `php` 하나) 나머지가 영구 차단된다 — 분류는 SSOT(df_bump_mode)에서 온다.
for L in go php dotnet java; do
  assert_ok run_manifest "$L" 0.1.0
  assert_ok run_manifest "$L" 9.9.9-rc.7   # 값과 무관하게 면제여야 한다(대조할 매니페스트가 없다)
done
# java의 회귀 그 자체: POM은 설계대로 `-SNAPSHOT`이므로 어떤 요청 버전과도 다르다.
assert_ok run_manifest java 0.1.0
# dotnet의 회귀 그 자체: csproj는 로컬 기본값이고 릴리스는 `-p:Version`으로 태그값을 주입한다.
assert_ok run_manifest dotnet 0.1.0-rc.2

# 수동범프 5종은 매니페스트와 **정확히** 일치할 때만 통과한다. 기대값은 추출 SSOT에서 읽는다.
manifest_version() { node "$ROOT/scripts/check-versions.mjs" --list | awk -v l="$1" '$1 == l { print $2 }'; }
manual_seen=0
for L in rust python node ruby kotlin; do
  v="$(manifest_version "$L")"
  assert_ok test -n "$v"          # SSOT가 값을 못 주면 아래 두 어서션이 무의미해진다
  assert_ok    run_manifest "$L" "$v"
  assert_fails run_manifest "$L" "${v}9"   # 대조군: 불일치는 반드시 거부된다
  manual_seen=$((manual_seen + 1))
done
assert_eq "5" "$manual_seen" "수동범프 5종을 전부 돌았다(루프가 조용히 비면 위 어서션이 0회다)"
# 미지 언어는 "면제"가 아니라 fail-closed여야 한다 — df_bump_mode가 빈 값을 주는 경우.
assert_fails run_manifest klingon 0.1.0
# 면제 판정이 산문(df_versionbump)이 아니라 기계가독 값에서 오는지 고정한다.
assert_contains "$(cat "$TMP/dispatch-manifest.sh")" 'df_bump_mode' "면제 분류를 df_bump_mode에서 가져온다"

# ── (3) 파생 태그 재검증 — `go/`는 이 워크플로가 절대 만들지 않는다 ────────────
# Go는 태그가 곧 게시이고 회수가 불가능하다(sum.golang.org는 append-only). release-request.sh의
# 거부가 1차 방어, 태그 룰셋 RELEASE-TAGS-CREATE-GO가 서버측 방어, 이것이 마지막 문자열 방어다.
assert_fails run_tagguard "go/v0.1.0"
assert_fails run_tagguard "refs/tags/v1.0.0"
assert_fails run_tagguard ''
assert_fails run_tagguard 'latest'
assert_fails run_tagguard '../v1.0.0'
assert_fails run_tagguard 'v0.1.0 go/v9.9.9'     # 공백 3필드 계약이 깨진 뒤의 잔해
assert_fails run_tagguard 'py-v0.1.0\c go/v9.9.9' # dash echo 우회의 잔해(리터럴 백슬래시)
# 여덟 언어의 정상 태그는 전부 통과해야 한다 — 형태를 좁히다 릴리스를 잠그면 안 된다.
# 태그 포맷은 하드코딩하지 않고 df_tag(SSOT)에서 만든다.
ok_tags=0
for L in $DEPLOY_LANGS; do
  [ "$L" = "go" ] && continue
  for V in 0.1.0 0.1.0rc2 0.1.0-rc.1 0.1.0.rc1 0.1.0-RC1 1.2.3.4 1.0.0+build.7; do
    assert_ok run_tagguard "$(printf "$(df_tag "$L")" "$V")"
    ok_tags=$((ok_tags + 1))
  done
done
assert_eq "56" "$ok_tags" "여덟 언어 × 일곱 표기가 전부 통과한다(줄이는 변경은 곧 커버리지 축소다)"
# 대조군: 같은 버전이라도 go 접두는 거부된다(위 통과가 "무조건 통과"가 아님을 보인다).
assert_fails run_tagguard "$(printf "$(df_tag go)" 0.1.0)"

# ── (4) proceed 게이팅 — no-op 실행에서 아무 스텝도 돌지 않아야 한다 ───────────
# 요청 파일이 리버트로 사라진 경우를 스펙은 "깨끗한 no-op"이라 약속한다. request 이후의 스텝이
# 하나라도 게이트를 빠뜨리면 그 약속이 깨진다(시크릿 가드가 그랬다 — 앞에 있어서, 할 일이 없는
# 실행이 App 시크릿 미설정으로 빨간불이 났다). 개수를 하드코딩하지 않고 세어서 비교한다.
steps_after="$(awk '/^      - /{ n++ } /id: request/{ mark = n } END { print n - mark }' "$WF")"
gates="$(grep -c "if: steps.request.outputs.proceed == 'true'" "$WF" || true)"
assert_ok test "$steps_after" -ge 5
assert_eq "$steps_after" "$gates" "request 이후 모든 스텝이 proceed 게이트를 갖는다"
# 시크릿 가드는 request **뒤**여야 한다(M1).
req_line="$(grep -n 'id: request' "$WF" | head -1 | cut -d: -f1)"
sec_line="$(grep -n 'RELEASE_APP_ID' "$WF" | head -1 | cut -d: -f1)"
assert_ok test "$req_line" -lt "$sec_line"

# ── (5) 룰셋 확인 — 세 이름 전부 + enforcement + 실패 시 중단 ──────────────────
# 스펙이 "Go 배제는 반드시 서버상태에 있어야 한다"고 못박은 룰셋이 RELEASE-TAGS-CREATE-GO인데
# 한때 그것만 빼놓고 봤다. enforcement가 evaluate/disabled면 아무것도 강제하지 않는다.
wf_text="$(cat "$WF")"
for R in RELEASE-TAGS-CREATE RELEASE-TAGS-CREATE-GO RELEASE-TAGS-IMMUTABLE; do
  assert_contains "$wf_text" "\"$R\"" "룰셋 확인이 $R 를 요구한다"
done
assert_contains "$wf_text" 'enforcement === "active"' "룰셋 확인이 enforcement까지 본다"
# 익명 API는 IP당 60/시간이고 러너 IP는 공유된다 — 403은 드물지 않다. 조회 실패를 경고로
# 흘려보내면 강제 장치가 사라진 상태에서도 태그가 밀린다. 이 저장소가 스스로 세운 원칙이다:
# "배포 시크릿 미설정은 '스킵'이 아니라 실패여야 한다."
assert_eq "0" "$(grep -c '::warning::' "$WF" || true)" "확인 불가를 경고로 흘려보내지 않는다(fail-closed)"

# ── (6) 출력 파싱 — dash의 echo가 백슬래시를 확장하는 경로를 쓰지 않는다 ───────
# `^[^#]*`로 주석 줄을 제외한다 — 왜 쓰면 안 되는지 설명하는 주석이 그 idiom을 인용하고 있다.
assert_eq "0" "$(grep -cE '^[^#]*echo "\$OUT"' "$WF" || true)" "출력 파싱에 echo를 쓰지 않는다"
assert_contains "$wf_text" '"$#" -ne 3' "출력의 공백 3필드 계약을 어서션한다"
# git ls-remote의 2(없음)와 128(전송/인증 실패)을 구분한다 — 구분하지 않으면 원격에 닿지도
# 못한 실행이 "태그 없음"으로 읽혀 그대로 태그 생성으로 넘어간다.
assert_contains "$wf_text" 'LS_RC' "ls-remote 종료코드를 받아 구분한다"

# ── (7) 이 워크플로는 게시하지 않는다 ─────────────────────────────────────────
# 디스패처가 직접 레지스트리를 건드리기 시작하면 "태그만 만든다"는 설계 경계가 무너진다.
assert_eq "0" "$(grep -cE '(npm|cargo|gem|twine|dotnet nuget) publish|gh release create' "$WF" || true)" "디스패처는 게시하지 않는다"

assert_report
