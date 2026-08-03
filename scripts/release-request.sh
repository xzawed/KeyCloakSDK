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
[ "${1:-}" = "--lib" ] || rq_main "$@"
