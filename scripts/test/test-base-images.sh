#!/usr/bin/env sh
# 하네스 Docker **베이스 이미지**가 조용히 갈리는 것을 막는다.
#
# ⚠️ **실측이 이 가드를 만들었다**(2026-09-15). 이미지 20 파일·26 `FROM`·13종인데
# **dependabot 10 생태계에 docker 가 없고**, 갈림을 잡는 가드도 0건이었다 — 프로브로 확인했다:
# 한 Dockerfile 의 `alpine:3.20` 만 `3.22` 로 옮기니 `check-versions.mjs` 도 `check-docs.mjs` 도
# **둘 다 SILENT**. 실제로 `alpine` 이 **3.20 둘 · 3.21 하나**로 갈려 있었다(같은 PR 에서 통일).
#
# 규칙은 하나다 — **같은 이미지 저장소는 한 태그로 움직인다.** 갈라야 할 이유가 있으면
# 아래 면제표에 **이유와 함께** 적는다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="${BI_ROOT:-$DIR/../..}"

# ⚠️ **픽스처는 제외한다** — `scripts/test/fixtures/**` 의 Dockerfile 은 *다른 가드*를 시험하려고
# 일부러 낡거나 어긋난 값을 들고 있다. 여기 넣으면 이 가드가 그 의도를 오탐으로 잡는다.
bi_files() { (cd "$ROOT" && git ls-files | grep -iE 'dockerfile' | grep -v '^scripts/test/fixtures/'); }

# `FROM` 한 줄 → `저장소<TAB>태그`. 멀티스테이지 별칭(`AS x`)과 플랫폼 인자는 떨군다.
bi_pairs() { # stdin=파일목록
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -hiE '^[[:space:]]*FROM[[:space:]]' "$ROOT/$f" 2>/dev/null \
      | sed 's/\r$//; s/[[:space:]]\{1,\}/ /g; s/^ //' \
      | sed 's/^[Ff][Rr][Oo][Mm] //; s/--platform=[^ ]* //; s/ [Aa][Ss] .*//' \
      | grep -vE '^[a-zA-Z0-9_-]+$' \
      | awk -F: '{ t=$NF; sub(/:[^:]*$/,"",$0); printf "%s\t%s\n", $0, t }'
  done
}

PAIRS="$(bi_files | bi_pairs | sort -u)"
_nf="$(printf '%s\n' "$PAIRS" | grep -c . || true)"
# 공허 하한 — 파싱이 깨지면 「갈린 것이 없어서」 초록이 된다. ⚠️ **세어서 박는다**: 실측 12 종
# (저장소·태그 조합, 2026-09-15). 처음에 15 로 지어냈다가 이 가드가 자기 자신을 빨갛게 했다 —
# 지어낸 상수는 required 체크를 잠근다(등록부가 이미 경고한 부류다). 여유 2 를 두고 10.
# ⚠️ **하한을 변수로 둔다 — 상수를 두 곳(검사·문구)에 적으면 갈린다.** 실제로 갈렸다:
# 조건을 10 으로 내리고 문구는 15 인 채로 뒀다(#496 이 소유자 축에서 고친 것과 같은 부류).
BI_MIN=10
_enough=1; [ "$_nf" -ge "$BI_MIN" ] && _enough=0
assert_eq "ok" "$(ok_if "$_enough" "$_nf")" \
  "[베이스 이미지] FROM 에서 저장소·태그 쌍을 ${BI_MIN}개 미만 뽑았다($_nf) — 파싱이 깨졌나?"

# ── 면제표 ───────────────────────────────────────────────────────────────────
# `저장소<TAB>이유`. **이유 없이 줄을 늘리지 말 것.**
BI_MULTI="$(cat <<'EOF'
eclipse-temurin	jdk 는 빌드 단계·jre 는 런타임 단계다 — 갈리는 것이 의도다(런타임에 컴파일러를 싣지 않는다)
EOF
)"

# 같은 저장소가 태그 둘 이상이면 운다(면제 제외).
_split=''
for repo in $(printf '%s\n' "$PAIRS" | cut -f1 | sort -u); do
  _tags="$(printf '%s\n' "$PAIRS" | awk -F'\t' -v r="$repo" '$1==r{print $2}' | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  case "$_tags" in *' '*) ;; *) continue ;; esac
  printf '%s\n' "$BI_MULTI" | cut -f1 | grep -qxF -- "$repo" && continue
  _split="$_split $repo($_tags)"
done
assert_eq "" "$_split" \
  "[베이스 이미지] 같은 저장소가 태그 둘 이상으로 갈렸다 —$_split (통일하거나 면제표에 이유를 적어라)"

# 떠다니는 태그 금지 — `latest` 나 태그 없음은 어제와 오늘이 다른 빌드를 만든다.
_float="$(printf '%s\n' "$PAIRS" | awk -F'\t' '$2=="latest" || $2=="" {print $1}' | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "" "$_float" "[베이스 이미지] 떠다니는 태그가 있다 —$_float"

# ⚠️ **면제표가 썩지 않게** — 면제한 저장소가 실제로 갈려 있지 않으면 표가 낡은 것이다.
_stale=''
for e in $(printf '%s\n' "$BI_MULTI" | cut -f1); do
  [ -n "$e" ] || continue
  _t="$(printf '%s\n' "$PAIRS" | awk -F'\t' -v r="$e" '$1==r{print $2}' | sort -u | grep -c . || true)"
  [ "$_t" -ge 2 ] || _stale="$_stale $e"
done
assert_eq "" "$_stale" "[베이스 이미지] 면제표에 **갈려 있지 않은** 저장소가 있다 — 표가 낡았다:$_stale"

_noreason="$(printf '%s\n' "$BI_MULTI" | awk -F'\t' 'NF<2 || $2=="" {print $1}' | tr '\n' ' ' | sed 's/ *$//')"
assert_eq "" "$_noreason" "[베이스 이미지] 이유 없는 면제가 있다:$_noreason"

assert_report
