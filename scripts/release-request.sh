#!/usr/bin/env sh
# release-request.sh — .github/release-request.json을 검증하고 릴리스 태그를 파생한다.
#
# ⚠️ 읽기전용: 어떤 상태도 변경하지 않는다(태그를 만들지 않는다 — 만드는 것은 워크플로다).
#
# 왜 태그가 요청 파일에 없는가: 태그를 데이터로 받으면
# {"lang":"python","version":"0.1.0rc2","tag":"node-v9.9.9"} 가 유효한 JSON으로 통과해
# **싼 언어를 선언하고 비싼 태그를 미는** 권한상승이 성립한다. 태그는 lang+version에서
# df_tag로 파생한다 — release-trigger.sh:22가 이미 쓰는 방식이다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
# release-readiness.sh와 같은 이유로 두 경로를 모두 시도한다(직접 실행 · 테스트에서 소싱).
if [ -f "$DIR/lib/deploy-facts.sh" ]; then
  . "$DIR/lib/deploy-facts.sh"
else
  . "$DIR/../lib/deploy-facts.sh"
fi

# JSON 파싱은 node에 맡긴다 — sed로 JSON을 긁으면 중첩·이스케이프에서 조용히 틀린다.
# 문자열이 아닌 값·파싱 실패는 빈 출력 + 비0으로 fail-closed.
rq_field() { # <file> <key> → stdout: 값
  node -e '
    const fs = require("fs")
    let obj
    try { obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8")) } catch { process.exit(1) }
    const v = obj[process.argv[2]]
    if (typeof v !== "string") process.exit(1)
    // ⚠️ 제어문자(특히 개행)를 여기서 막는다. 아래 rq_validate_file의 버전 검사는
    // `grep -qE "^...$"` 인데 POSIX grep의 ^/$ 는 "문자열 전체"가 아니라 "줄" 단위다 —
    // JSON의 \n 이스케이프가 실제 개행으로 복원되면 필드값이 여러 줄이 되고, 그 중
    // 한 줄만 정규식을 만족해도 grep -q가 통과한다(예: version이
    // "0.1.0\nnode-v9.9.9"). 그러면 stdout도 두 줄이 되어 "<lang> <version> <tag>"를
    // 위치 인자로 읽는 다운스트림이 태그 대신 공격자가 넣은 두 번째 줄을 $3으로 받는다 —
    // "싼 언어를 선언하고 비싼 태그를 민다"가 tag 필드가 아니라 version을 통해 성립한다
    // (코드리뷰에서 발견). 값이 이 함수를 통과하는 유일한 지점이므로 여기서 한 번
    // 막으면 lang·version·향후 추가되는 어떤 필드에도 같은 방어가 자동 적용된다.
    if (/[\x00-\x1f\x7f]/.test(v)) process.exit(1)
    process.stdout.write(v)
  ' "$1" "$2" 2>/dev/null
}

rq_derive_tag() { # <lang> <version> → stdout: 태그
  printf "$(df_tag "$1")" "$2"
}

rq_validate_file() { # <path> → stdout: "<lang> <version> <tag>" · 0=진행 1=거부 3=요청없음
  f="$1"
  if [ ! -f "$f" ]; then
    echo "릴리스 요청 파일이 없다: $f — 할 일 없음(no-op)" >&2
    return 3
  fi

  lang="$(rq_field "$f" lang)" || lang=""
  ver="$(rq_field "$f" version)" || ver=""
  if [ -z "$lang" ] || [ -z "$ver" ]; then
    echo "::error::릴리스 요청을 읽지 못했다($f) — lang·version 문자열 필드가 필요하다(fail-closed)." >&2
    return 1
  fi

  if ! df_known "$lang"; then
    echo "::error::미지의 언어 '$lang' — 지원: $DEPLOY_LANGS" >&2
    return 1
  fi

  # ⚠️ Go는 자동화하지 않는다. 태그가 곧 게시라(proxy가 CI를 기다리지 않는다) 머지 이후에
  # 어떤 게이트도 둘 수 없고, sum.golang.org가 append-only라 태그를 고쳐 다시 밀면 기존
  # 소비자가 checksum mismatch를 본다 — 아홉 중 복구 시도가 원래 사고보다 해로운 유일한 곳이다.
  # 이 거부는 두 번째 방어선이다. 첫 번째는 태그 룰셋(RELEASE-TAGS-CREATE-GO)이며, 그쪽은
  # 이 워크플로를 수정해도 우회되지 않는다.
  if [ "$lang" = "go" ]; then
    echo "::error::go는 자동 릴리스 대상이 아니다 — 태그가 곧 게시이고 회수가 불가능하다." >&2
    echo "  사람이 직접 실행한다: git tag go/v${ver} && git push origin go/v${ver}" >&2
    return 1
  fi

  # 버전 표기는 레지스트리마다 다르다(PEP 440 · RubyGems · Maven · SemVer). 언어별 정규식으로
  # 검사하는 것은 오타 방지이자 **주입 차단**이다 — 이 값이 태그 문자열과 명령에 삽입된다.
  if ! echo "$ver" | grep -qE "$(df_version_re "$lang")"; then
    echo "::error::'$lang'의 버전 표기가 아니다: '$ver'" >&2
    echo "  기대: $(df_version_hint "$lang")" >&2
    return 1
  fi

  printf '%s %s %s\n' "$lang" "$ver" "$(rq_derive_tag "$lang" "$ver")"
  return 0
}

rq_main() {
  rq_validate_file "${1:-.github/release-request.json}"
}

# --lib: 함수만 로드(테스트용). 그 외: main 실행.
#
# ⚠️ 소싱하는 쪽은 반드시 **소싱 전에** 위치인자를 설정해야 한다 — 인자를 dot에 직접 넘기면 안 된다:
#     set -- --lib
#     . "$SH"
# POSIX의 `.`(dot)은 파일명 외의 인자를 정의하지 않는다. bash는 호의로 위치인자를 설정하지만
# **dash는 조용히 무시한다**. 우분투 러너의 `/bin/sh`가 dash라, `. "$SH" --lib`로 쓰면 CI에서만
# `$1`이 비어 rq_main이 기본 경로로 실행되고(요청 파일 부재 → return 3) 호출자의 `set -e`가
# 테스트를 죽인다. 로컬 Git Bash(bash)와 busybox ash는 둘 다 통과하므로 이 차이는 CI에서만 보인다.
# release-readiness.sh도 같은 가드를 쓴다 — 넷(스크립트 2·테스트 2)이 같은 방식이어야 한다.
[ "${1:-}" = "--lib" ] || rq_main "$@"
