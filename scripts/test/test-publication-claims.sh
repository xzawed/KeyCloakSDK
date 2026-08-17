#!/usr/bin/env sh
# 각 `<lang>/README.md`의 프리릴리스 배너가 실제 게시 현황(DF_PUBLISHED)과 맞는가.
#
# 왜 이 가드가 필요한가: 이 README들은 **레지스트리 랜딩 페이지**가 된다. 패키지 안에 담겨
# 올라가고, 레지스트리는 README를 **버전마다 고정**한다 — 게시 후에 고치려면 새 버전을 태워야
# 한다(DEPLOY.md §4 step 1의 경고). 그래서 "게시했는데 배너가 아직 미게시라고 말하는" 실수는
# 되돌리는 데 좌표 하나가 든다. 9개 언어를 손으로 맞춰 왔고 지금은 전부 맞지만, 남은 5개를
# 게시하는 동안 다섯 번 더 틀릴 기회가 있다.
#
# ⚠️ 이 어서션은 **양방향이라야 의미가 있다**. "미게시면 '아직'이라고 적혀 있어야 한다"만
# 검사하면 게시 후 배너를 안 고쳐도 통과하고, 그 반대만 검사하면 새 언어가 추가될 때 빈
# 배너를 통과시킨다. `DF_PUBLISHED` 한 줄을 옮기는 순간 **양쪽이 동시에** 요구된다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
ROOT="$DIR/../.."

# ⚠️ **여기 있던 `UNPUBLISHED_INSTALL_VER="0.1.0-rc.1"`은 2026-08-17 go 게시로 제거했다.**
# 그 상수는 "미게시 언어의 설치 스니펫이 첫 태그에 무엇을 적어야 하는가"에 대한 **예측**이었고,
# 예측 대상은 go 하나였다(`go/v0.1.0`은 존재한 적이 없다). 이제 그 예측은 사실이 되어
# `df_published_version go`가 들고 있으므로, 상수는 (a) 아홉 전부 게시된 지금 도달 불가이고
# (b) 열 번째 언어가 생겨 다시 도달 가능해지는 순간에는 **그 언어의 첫 태그 버전을 알 수 없어
# 틀린 값을 단언**하게 된다. 그래서 조용한 폴백 대신 아래 `-n` 어서션으로 바꿨다 — 미게시
# 언어가 다시 생기면 "기대값을 모른다"고 시끄럽게 실패하고, 사람이 그때 값을 정한다.
# (같은 이유로 호환성 표 루프의 `0.1.0` 폴백도 함께 제거했다.)

for L in $DEPLOY_LANGS; do
  f="$ROOT/$L/README.md"
  assert_ok test -f "$f"

  # 배너는 첫머리에 있어야 한다 — 소비자가 레지스트리 페이지에서 처음 보는 줄이다.
  #
  # ⚠️ **마커는 라벨을 보지 않는다.** 예전에는 `^> \*\*Pre-release\*\*`로 찾았는데, 아홉이
  # 전부 정식 게시되면서 그 라벨 자체가 틀린 값이 됐고 배너를 고치면 가드가 배너를 **못 찾아**
  # 실패했다(추출 실패는 "낡았다"와 구분되지 않는다). 지금은 첫머리의 **굵은 인용줄**을
  # 배너로 본다 — 아홉 전부 7행에 정확히 하나이고(실측), 게시/미게시 판정은 아래 내용
  # 어서션이 한다. 라벨을 다시 하드코딩하지 말 것.
  banner="$(sed -n '1,12p' "$f" | grep -m1 '^> \*\*' || true)"
  assert_ok test -n "$banner"
  [ -n "$banner" ] || continue

  if df_is_published "$L"; then
    # 게시됨: "아직"이라고 말하면 안 되고, **어디에 있는지**를 말해야 한다. 부정형만 지우고
    # 아무것도 안 적는 절반짜리 수정을 막으려고 긍정 어서션을 함께 둔다.
    assert_not_contains "$banner" "not yet" \
      "$L 은 게시됐는데 README 배너가 아직 미게시라고 말한다 — 이 README는 레지스트리 랜딩 페이지다"
    assert_contains "$banner" "is on " \
      "$L 배너가 어느 레지스트리에 올라가 있는지 말하지 않는다"
  else
    assert_contains "$banner" "not yet" \
      "$L 은 미게시인데 README 배너가 그렇게 말하지 않는다"
    assert_not_contains "$banner" "is on " \
      "$L 은 미게시인데 배너가 레지스트리에 올라가 있다고 말한다"
  fi

  # ---- 설치 스니펫에 **핀된 버전** ----
  #
  # ⚠️ 배너만 검사하면 **설치 스니펫이 낡은 채로 통과한다.** `java/README.md`가 실제로 그랬다 —
  # 배너는 게시형으로 고쳐졌는데 설치 예제 두 곳은 `0.1.0`이었고, 게시된 것은 `0.1.0-RC1`뿐이라
  # 소비자에게 **존재하지 않는 좌표**를 권하고 있었다(가드는 초록, 사람이 손으로 발견).
  # 레지스트리는 README를 버전마다 고정하므로 이 실수를 고치려면 좌표 하나를 더 태워야 한다.
  #
  # ⚠️ **파일 전체 containment로는 못 잡는다 — 실제로 시도했다가 변이가 통과했다.** 배너 산문에
  # 게시 버전이 들어 있으면(`the first release candidate (\`0.1.0-RC1\`) is on …`) 스니펫이 옛 값
  # 이어도 "파일 어딘가에 있다"가 성립한다. 그래서 **코드펜스 안**만 본다.
  #
  # ⚠️ "펜스 안에 게시 버전이 있어야 한다"도 틀렸다 — python·rust·dotnet·php는 설치 명령에 버전을
  # 쓰지 않는 것이 **옳다**(`pip install keycloak-sdk`처럼 리졸버가 고르게 둔다). 그래서 규칙은
  # "있어야 한다"가 아니라 **"핀했다면 그 값이어야 한다"** 이다. 기대값은 `df_published_version`
  # 하나뿐이라, 게시로 그 값이 바뀌면 스니펫을 안 고친 언어에서 시끄럽게 깨진다.
  _want="$(df_published_version "$L")"
  if [ -z "$_want" ]; then
    assert_ok false "$L 의 df_published_version 이 비어 있다 — 미게시 언어의 설치 스니펫 기대 버전은 사람이 정해야 한다"
    continue
  fi
  _bad="$(awk '/^```/ { f = !f; next } f' "$f" \
    | grep -oE '0\.1\.0[A-Za-z0-9.-]*' | sort -u | grep -Fxv "$_want" || true)"
  assert_eq "" "$_bad" \
    "$L/README.md 코드펜스에 핀된 버전이 기대값($_want)과 다르다 — 소비자에게 없는 좌표를 권하게 된다"
done

# ⚠️ 대조군 — 위 루프가 실제로 언어를 돌았는지 확인한다. `DEPLOY_LANGS`가 비거나 파일 경로
# 규칙이 바뀌면 어서션이 0건 실행되고 이 테스트는 조용히 통과한다(그게 이 저장소가 반복해서
# 겪은 실패다). 개수를 SSOT에서 파생해 맞춘다.
n=0
for L in $DEPLOY_LANGS; do n=$((n + 1)); done
assert_ok test "$n" -ge 9

# ---- 루트 문서의 게시 현황 주장 ----
#
# `deploy-facts.sh`의 주석이 스스로 열거하듯 rust RC 한 번이 최소 6곳을 동시에 낡게 만들었다.
# 그중 기계 대조가 붙은 것은 DEPLOY.md(test-deploy-md.sh)와 위의 패키지 README뿐이었고,
# **랜딩 문서 셋(README·README.ko·SECURITY)과 getting-started는 손으로만 맞춰져 있었다.**
pub_n=0;  for L in $DF_PUBLISHED; do pub_n=$((pub_n + 1)); done
unpub_n=$((n - pub_n))
en() { case "$1" in
  1) echo one ;; 2) echo two ;; 3) echo three ;; 4) echo four ;; 5) echo five ;;
  6) echo six ;; 7) echo seven ;; 8) echo eight ;; 9) echo nine ;; *) echo "" ;; esac; }
ko() { case "$1" in
  1) echo 하나 ;; 2) echo 둘 ;; 3) echo 셋 ;; 4) echo 넷 ;; 5) echo 다섯 ;;
  6) echo 여섯 ;; 7) echo 일곱 ;; 8) echo 여덟 ;; 9) echo 아홉 ;; *) echo "" ;; esac; }
pub_en="$(en "$pub_n")"; unpub_en="$(en "$unpub_n")"
pub_ko="$(ko "$pub_n")"; unpub_ko="$(ko "$unpub_n")"
# ⚠️ `en 0`/`ko 0`은 의도적으로 빈 문자열이다 — "0개가 미게시"를 수사로 쓰는 문장은 없어야 하고,
# 있다면 그건 "전부 게시됐다"로 다시 쓰여야 한다. 그래서 미게시 수사는 미게시가 실제로 있을
# 때만 요구한다(예전엔 무조건 요구해 9/9 전환에서 이 어서션이 먼저 터졌다).
assert_ok test -n "$pub_en" -a -n "$pub_ko"
if [ "$unpub_n" -ge 1 ]; then
  assert_ok test -n "$unpub_en" -a -n "$unpub_ko"
fi

# 영문 랜딩 문서 — 대소문자 두 형태를 모두 허용한다(문장 첫머리면 "Four", 아니면 "four").
#
# ⚠️ **`getting-started.md`가 여기 들어 있는 이유.** 이 파일은 아래에서 설치 절 **개수**로도
# 대조되지만, 그것만으로는 상단의 산문 배너("Five of the nine are on a public registry …")를
# 보지 못한다. 실제로 Ruby를 게시하는 PR에서 설치 절은 뒤집혔는데 그 배너만 "Four … The other
# five (…, Ruby, …)"로 남았고, 구조 검사가 초록이라 아무도 몰랐다 — 이 저장소에서 가장 많이
# 읽히는 문서에 거짓이 남은 것이다. 구조와 산문은 서로를 대신하지 못하므로 둘 다 본다.
#
# ⚠️ **파일 전체가 아니라 그 주장을 담은 줄만 본다.** 처음에는 `case "$(cat "$f")" in *five*`
# 처럼 파일 전체를 뒤졌는데, `getting-started.md`는 700줄이라 "five"가 어디선가 우연히 등장해
# **배너를 낡은 값으로 되돌려도 통과했다**(실측). 세 문서 모두 이 주장을 한 문장에만 쓰므로
# 그 문장을 앵커로 뽑는다 — 앵커를 못 찾으면 그것도 실패다(문구를 바꾸면 조용히 넘어가는 대신
# 시끄럽게 실패해야 한다).
for f in README.md SECURITY.md docs/guides/getting-started.md; do
  # 앵커 줄 + 뒤 2줄. SECURITY.md는 그 문장이 하드랩돼 있어 한 줄로는 수사를 놓친다.
  # ⚠️ 앵커 정규식에 **정식 수사도** 넣는다 — RC 문구만 겨누면 정식 전환 때 앵커를 못 찾아
  # "낡았다"가 아니라 "추출 실패"로 떨어진다(배너 마커에서 겪은 것과 같은 부류).
  claim="$(grep -m1 -A2 -E 'on a public registry|shipped a first|shipped their first|shipped a stable' "$ROOT/$f" || true)"
  assert_ok test -n "$claim"
  [ -n "$claim" ] || continue
  up="$(printf '%s' "$pub_en" | sed 's/^./\U&/')"
  case "$claim" in
    *"$pub_en"*|*"$up"*) : ;;
    *) assert_ok false "$f 의 게시 현황 문장이 개수($pub_n=$pub_en)를 말하지 않는다" ;;
  esac
done

# 미게시 수사는 **자리를 명시해서** 대조한다. 산문을 일반 파싱하려던 두 시도가 모두 실패했다:
#   (1) 파일 전체에서 `other <수사>` 찾기 → 게시와 무관한 "the other eight languages"(보여준
#       언어 말고 나머지 여덟)까지 걸려 오탐.
#   (2) registry/published를 언급하는 **줄**로 좁히기 → `SECURITY.md`는 그 문장이 하드랩돼
#       "(`0.1.0.rc1`, RubyGems). The other four" 줄에 그 키워드가 없어 **0건**이 됐다.
# 그래서 어디에 무엇이 적혀 있어야 하는지를 그냥 적는다. 문구를 바꾸면 시끄럽게 실패하고,
# 그때 이 목록을 함께 고치는 것이 맞다 — DEPLOY.md 가드가 쓰는 것과 같은 관용이다.
claim_at() { # $1=파일 $2=기대 문자열 $3=자리 이름
  assert_contains "$(cat "$ROOT/$1")" "$2" "$1 의 $3 가 DF_PUBLISHED 파생 게시/미게시 수($pub_n/$unpub_n)와 다르다"
}
Pub_en="$(printf '%s' "$pub_en" | sed 's/^./\U&/')"

# ---- 게시 현황 수사를 자리마다 강제한다 ----
#
# 아래 자리 목록의 유래(왜 자리를 그냥 적는가, 왜 이만큼 많은가):
#   * 산문을 일반 파싱하려던 두 시도가 모두 실패했다 — (1) 파일 전체에서 `other <수사>` 찾기는
#     게시와 무관한 "the other eight languages"(보여준 언어 말고 나머지 여덟)까지 걸려 오탐,
#     (2) registry/published를 언급하는 **줄**로 좁히기는 `SECURITY.md`의 하드랩 때문에 0건.
#   * 2026-08-10: 랜딩 문서만 겨눈 탓에 CLAUDE.md·DEPLOY.md·CHANGELOG.md·roadmap 네 곳이
#     `4개 / 나머지 5개`에 멈춘 채 자가테스트 15종이 전부 초록이었다.
#   * 2026-08-12: **같은 문서가 같은 사실을 여러 자리에서 말한다** — DEPLOY.md 네 자리,
#     language-support 머리말+매트릭스. 82개 어서션이 초록인 채로 한 문서가 자기를 반박했다.
# ⚠️ README.md는 **두 곳**이다(상단 배너 + 하단 서술). 하나만 검사하면 다른 쪽이 낡어도 통과한다.
#
# ---- 2026-08-17: 이 블록의 **방향이 뒤집혔다** ----
#
# 예전 이 자리에는 `assert_ok test "$unpub_n" -ge 1`이 있었고, 바로 위 주석은 "미게시가 0이 되면
# 이 문장들은 존재해선 안 된다 — 수사 치환이 아니라 문장 교체라 자동으로 만들 수 없으므로 그
# 순간 시끄럽게 실패시켜 사람이 다시 쓰게 한다"였다. **go 첫 게시가 설계대로 그것을 터뜨렸다**
# (32건 실패: 이 파일 28 + test-deploy-md.sh 4).
#
# 그래서 가드를 **약화시키지 않고 방향만 바꾼다**: 미게시 수사를 강제하던 자리를 그대로 두되,
# 전부 게시된 동안에는 **"전부 게시" 수사**를 강제한다. 두 갈래를 **둘 다 남기는** 이유는 열
# 번째 언어가 미게시로 추가되는 순간 "전부 게시" 문장들이 다시 거짓이 되기 때문이다 — 그때는
# else 가지가 자동으로 재무장해 옛 수사를 요구한다. 어느 상태에서도 문서가 SSOT를 따라오지
# 않으면 시끄럽게 실패한다.
#
# ⚠️ **수·복수를 가려야 한다 — 안 그러면 가드가 비문을 강제한다.** 미게시가 1개면
# `the other one languages are …`를, 0개면 `나머지 0 언어`를 요구하게 되고, 문서를 옳은 말로
# 쓰면 CI가 빨개진다(가드가 문서를 틀리게 만드는 상태 — `test-deploy-md.sh` 상단이 기록한
# "zero tags" 실패와 같은 부류다).
# ---- 2026-08-17(2): 갈래가 하나 더 늘었다 — 게시 여부만으로는 부족하다 ----
#
# 위 갈래는 **게시/미게시**만 본다. 아홉이 전부 `0.1.0` 정식으로 올라가자 그 이분법으로는
# 잡히지 않는 상태가 생겼다: 게시 주장은 여전히 참인데 **"첫 RC"·"정식 없음" 수사가 거짓**이
# 된다. 실제로 `claim_at`이 전부 초록인 채로 여덟 문서가 "no stable release yet"을 말하고
# 있었다(가드가 문구 **접두**를 보기 때문이다).
#
# 그래서 판정을 SSOT에서 파생한다 — 하드코딩이 아니라 `df_published_version`이 프리릴리스
# 표기인지 센다. 갈래를 **둘 다 남기는** 이유는 위와 같다: 열 번째 언어가 RC로 첫 게시되는
# 순간 RC 수사가 다시 옳아지고 그 가지가 자동으로 재무장한다.
prerel_n=0
for _l in $DEPLOY_LANGS; do
  _v="$(df_published_version "$_l")"
  [ -n "$_v" ] || continue
  if df_is_prerelease "$_v"; then prerel_n=$((prerel_n + 1)); fi
done

if [ "$unpub_n" -eq 0 ] && [ "$prerel_n" -eq 0 ]; then
  # 아홉 전부 **정식** 게시. RC 수사와 "정식 없음"은 존재해선 안 된다.
  claim_at README.md "Stable \`0.1.0\` is live for all $pub_en languages"        "상단 배너"
  claim_at README.md "All $pub_en have shipped a stable release"                 "하단 서술"
  claim_at SECURITY.md "All $pub_en SDKs have shipped a stable"                  "게시 열거"
  claim_at docs/guides/getting-started.md "All $pub_en are on a public registry" "상단 배너"

  claim_at CLAUDE.md "${pub_n}개 언어 전부 정식 \`0.1.0\`이 공개 레지스트리에 게시됐다" "현재 상태(게시 수)"
  claim_at CLAUDE.md "9개 중 ${pub_n}개가 정식 게시"                                    "문서 언어 규칙 절"

  claim_at DEPLOY.md "**all $pub_en languages are published"        "릴리스 워크플로 상태(게시 수)"
  claim_at CHANGELOG.md "지금까지 ${pub_ko} 언어 전부가"             "폴리글랏 안내(게시 수)"

  claim_at docs/roadmap/language-support.md "**All $pub_en are now live as stable releases**" "step-0(게시 수)"
  claim_at DEPLOY.md "All $pub_en languages have now published"     "§7 첫 실행 경고(게시 수)"
  claim_at docs/roadmap/language-support.md "all $pub_en have since shipped a stable release" "머리말(게시 수)"

  # ⚠️ 부정 어서션 — 긍정만 걸면 정식 문장을 **추가**하고 옛 "정식 없음"을 **남겨둔** 자기모순이
  # 통과한다. 위 published/unpublished 갈래가 「미게시」로 막는 것과 같은 부류다.
  for _cf in README.md README.ko.md SECURITY.md DEPLOY.md CLAUDE.md \
             docs/guides/getting-started.md docs/roadmap/language-support.md; do
    _ct="$(cat "$ROOT/$_cf")"
    assert_not_contains "$_ct" "no stable release yet" \
      "$_cf 에 아홉 전부 정식 게시인데 「정식 없음」 수사가 남아 있다"
    assert_not_contains "$_ct" "No language has a stable release" \
      "$_cf 에 아홉 전부 정식 게시인데 「정식 없음」 수사가 남아 있다"
    assert_not_contains "$_ct" "정식(stable) 릴리스는 아직" \
      "$_cf 에 아홉 전부 정식 게시인데 「정식 없음」 수사가 남아 있다"
  done
elif [ "$unpub_n" -eq 0 ]; then
  # 아홉 전부 게시됐으나 일부(또는 전부)가 프리릴리스. "나머지 N개" 수사는 존재해선 안 된다.
  claim_at README.md "First release candidates are live for all $pub_en languages" "상단 배너"
  claim_at README.md "All $pub_en have shipped their first release candidates"     "하단 서술"
  claim_at SECURITY.md "All $pub_en SDKs have shipped a first"                     "게시 열거"
  claim_at docs/guides/getting-started.md "All $pub_en are on a public registry"   "상단 배너"

  claim_at CLAUDE.md "${pub_n}개 언어 전부 첫 RC가 공개 레지스트리에 게시됐다" "현재 상태(게시 수)"
  claim_at CLAUDE.md "9개 중 ${pub_n}개가 첫 RC 게시"                          "문서 언어 규칙 절"

  claim_at DEPLOY.md "**all $pub_en languages are published"        "릴리스 워크플로 상태(게시 수)"
  claim_at CHANGELOG.md "지금까지 ${pub_ko} 언어 전부가"             "폴리글랏 안내(게시 수)"

  claim_at docs/roadmap/language-support.md "**All $pub_en are now live as release candidates**" "step-0(게시 수)"
  claim_at DEPLOY.md "All $pub_en languages have now published"     "§7 첫 실행 경고(게시 수)"
  claim_at docs/roadmap/language-support.md "all $pub_en have since shipped a first release candidate" "머리말(게시 수)"

  # ⚠️ 부정 어서션 — 긍정만 걸면 "전부 게시" 문장을 **추가**하고 옛 "나머지 N개" 문장을 **남겨둔**
  # 자기모순 상태가 통과한다(2026-08-12 감사가 찾은 부류가 정확히 그것이다).
  for _cf in README.md README.ko.md SECURITY.md DEPLOY.md CHANGELOG.md CLAUDE.md \
             docs/guides/getting-started.md docs/roadmap/language-support.md; do
    _ct="$(cat "$ROOT/$_cf")"
    assert_not_contains "$_ct" "is unpublished"  "$_cf 에 아홉 전부 게시인데 미게시 수사가 남아 있다"
    assert_not_contains "$_ct" "are unpublished" "$_cf 에 아홉 전부 게시인데 미게시 수사가 남아 있다"
    assert_not_contains "$_ct" "is not on a registry yet" "$_cf 에 아홉 전부 게시인데 미게시 수사가 남아 있다"
    assert_not_contains "$_ct" "미게시"          "$_cf 에 아홉 전부 게시인데 「미게시」가 남아 있다"
  done
else
  if [ "$unpub_n" -eq 1 ]; then
    _en_banner="the other language is not on a registry yet"
    _en_other="The other one"
    _ko_other="나머지 한 언어"
    _dep_unpub="and $unpub_en is not.**"
  else
    _en_banner="the other $unpub_en languages are not on a registry yet"
    _en_other="The other $unpub_en"
    _ko_other="나머지 $unpub_ko 언어"
    _dep_unpub="and $unpub_en are not.**"
  fi
  Unpub_en="$(printf '%s' "$unpub_en" | sed 's/^./\U&/')"

  claim_at README.md "$_en_banner" "상단 배너"
  claim_at README.md "the remaining $unpub_en (" "하단 서술"
  claim_at SECURITY.md "$_en_other" "미게시 열거"
  claim_at docs/guides/getting-started.md "The other $unpub_en (" "상단 배너"

  claim_at CLAUDE.md "${pub_n}개는 첫 RC가 공개 레지스트리에 게시됐다" "현재 상태(게시 수)"
  claim_at CLAUDE.md "나머지 ${unpub_n}개("                            "현재 상태(미게시 수)"
  claim_at CLAUDE.md "9개 중 ${pub_n}개만 첫 RC 게시"                  "문서 언어 규칙 절"

  claim_at DEPLOY.md "**$pub_en of nine languages are published"       "릴리스 워크플로 상태(게시 수)"
  claim_at DEPLOY.md "$_dep_unpub"                                     "릴리스 워크플로 상태(미게시 수)"

  claim_at CHANGELOG.md "지금까지 ${pub_ko} 언어가"                     "폴리글랏 안내(게시 수)"
  claim_at CHANGELOG.md "나머지 ${unpub_ko}("                           "폴리글랏 안내(미게시 수)"

  claim_at docs/roadmap/language-support.md "**$Pub_en are now live as release candidates**" "step-0(게시 수)"
  claim_at docs/roadmap/language-support.md "the remaining $unpub_en ("                      "step-0(미게시 수)"

  claim_at DEPLOY.md "$Unpub_en of the nine languages"                 "§7 첫 실행 경고(미게시 수)"
  claim_at DEPLOY.md "The $pub_en languages that have published"       "§7 RC 선례(게시 수)"
  claim_at docs/roadmap/language-support.md "$pub_en of them (all except" "머리말(게시 수)"
fi

# 상태와 무관하게 게시 **수**만 말하는 자리(수사 형태가 갈리지 않는다).
claim_at DEPLOY.md "$Pub_en release workflows have now executed end to end" "§5 실행 워크플로 수"

# ⚠️ 상태 매트릭스는 산문이 아니라 **행 개수**로 본다 — `getting-started`의 설치 절 개수 검사와
# 같은 관용이다. 표현을 바꿔도 흔들리지 않고, 감사가 찾은 부류(게시됐는데 `🔒 human-gated`로 남은
# 행)를 정확히 겨눈다. ⚠️ **양방향이라야 한다** — 미게시만 세면 게시 행을 지워버려도 통과하고,
# 게시만 세면 미게시 행이 바뀌어도 통과한다. 그래서 언어 행 **총수**를 함께 고정한다.
#
# ⚠️ **패턴에 이모지를 쓰지 않는다 — 환경에 따라 매치가 갈린다.** 처음에는 `grep -c '🔒 …'`로
# 셌는데, 같은 트리·같은 파일에서 이 PC의 GNU grep 3.0은 1/8을 세고 다른 환경(MSYS grep)은
# **0/0**을 세어 어서션 둘이 실패했다. 실패 방향은 fail-closed라 위험하진 않지만, **문서가
# 멀쩡한데 CI가 빨개지는** 부류다. `human-gated`와 행 머리 `| **`는 순수 ASCII라 갈리지 않는다.
lsm="$ROOT/docs/roadmap/language-support.md"
# ⚠️ **`|| true`가 없으면 0건에서 스크립트가 통째로 죽는다.** `grep -c`는 매치가 없으면 `0`을
# 출력하고 **exit 1**을 낸다. 이 파일은 `set -e`라 대입문의 종료코드가 그대로 셸을 끝내고,
# `assert_report`에 도달하지 못해 **출력 한 줄 없이 exit 1**이 된다(어서션 실패 메시지도, 남은
# 어서션도 사라진다 — fail-closed지만 원인을 못 읽는다). 아홉 전부 게시되어 human-gated 행이
# 0이 되는 순간 실제로 그렇게 죽었다(2026-08-17 실측).
_rows_all="$(grep -c '^| \*\*' "$lsm" || true)"
_rows_gated="$(grep -c 'human-gated |' "$lsm" || true)"
assert_eq "$n" "$_rows_all" \
  "language-support 상태 매트릭스의 언어 행 수가 DEPLOY_LANGS 개수($n)와 다르다 — 행 표기가 바뀌었나?"
assert_eq "$unpub_n" "$_rows_gated" \
  "language-support 상태 매트릭스의 human-gated(미게시) 행 수가 DF_PUBLISHED 파생 미게시 수($unpub_n)와 다르다"
assert_eq "$pub_n" "$((_rows_all - _rows_gated))" \
  "language-support 상태 매트릭스의 게시 행 수(총 행 − human-gated)가 DF_PUBLISHED 파생 게시 수($pub_n)와 다르다"

# 한글 미러 — 영문과 같은 사실을 한글 수사로 말한다(README.md와 동일 구조의 미러라는 규칙).
ko_t="$(cat "$ROOT/README.ko.md")"
if [ "$unpub_n" -eq 0 ] && [ "$prerel_n" -eq 0 ]; then
  # 두 자리를 **서로 다른 문자열**로 겨눈다 — 한쪽만 고치고 다른 쪽을 남기는 절반짜리 수정을
  # 막기 위해서다(영문 README와 같은 이유로 상단/하단이 나뉘어 있다).
  assert_contains "$ko_t" "$pub_ko 언어 전부 정식 \`0.1.0\`이 공개 레지스트리에 게시됐습니다" \
    "README.ko.md 상단 배너가 DF_PUBLISHED 파생 게시수($pub_n)를 '전부'로 말하지 않는다"
  assert_contains "$ko_t" "$pub_ko 전부 정식 릴리스를 공개 레지스트리에 게시했습니다" \
    "README.ko.md 하단 서술이 DF_PUBLISHED 파생 게시수($pub_n)를 '전부'로 말하지 않는다"
elif [ "$unpub_n" -eq 0 ]; then
  assert_contains "$ko_t" "$pub_ko 언어 전부 첫 릴리스 후보(RC)가 공개 레지스트리에 게시됐습니다" \
    "README.ko.md 상단 배너가 DF_PUBLISHED 파생 게시수($pub_n)를 '전부'로 말하지 않는다"
  assert_contains "$ko_t" "$pub_ko 전부 첫 릴리스 후보(RC)를 공개 레지스트리에 게시했습니다" \
    "README.ko.md 하단 서술이 DF_PUBLISHED 파생 게시수($pub_n)를 '전부'로 말하지 않는다"
else
  assert_contains "$ko_t" "아홉 중 $pub_ko" "README.ko.md 의 게시 개수가 DF_PUBLISHED 파생값($pub_n)과 다르다"
  assert_contains "$ko_t" "$_ko_other" "README.ko.md 의 미게시 개수가 DF_PUBLISHED 파생값($unpub_n)과 다르다"
fi

# ⚠️ getting-started는 산문이 아니라 **구조**로 대조한다 — 언어마다 설치 절이 두 형태 중
# 하나이고, 그 개수가 곧 게시 현황이다. 산문 수사와 달리 표현을 바꿔도 흔들리지 않는다.
gs="$ROOT/docs/guides/getting-started.md"
# ⚠️ `|| true` — 위 매트릭스 카운트와 같은 이유다(0건이면 `grep -c`가 exit 1 → `set -e`가 죽인다).
# 아홉 전부 게시되면 '미게시' 설치 절은 정확히 0건이라야 하므로 이쪽이 정상 상태다.
assert_eq "$unpub_n" "$(grep -c '^### 3) Installation after release (future)$' "$gs" || true)" \
  "getting-started의 '미게시' 설치 절 수 ≠ DF_PUBLISHED 파생 미게시 수"
assert_eq "$pub_n" "$(grep -c '^### 3) Installation from ' "$gs" || true)" \
  "getting-started의 '게시됨' 설치 절 수 ≠ DF_PUBLISHED 파생 게시 수"

# ---- 호환성 표의 **버전 문자열** ↔ df_published_version ----
#
# ⚠️ 위 어서션들은 전부 "몇 개가 게시됐나"만 본다. **어떤 버전이 게시됐나는 아무도 안 봤다** —
# 그래서 이 표는 아홉 행 중 일곱이 `0.1.0`에 멈춘 채 여섯 번의 게시를 그대로 통과했다(2026-08-10
# 발견). 개수와 버전은 같은 사실의 다른 축이고, 소비자가 실제로 복사해 가는 쪽은 버전이다.
#
# ⚠️ 여기 있던 `[ -n "$_want" ] || _want="0.1.0"`(미게시 행 = 현재 `main` = 라인 버전) 폴백도
# 2026-08-17에 제거했다 — 아홉 전부 게시라 도달 불가이고, 열 번째 언어가 생겨도 그 언어의 라인
# 버전을 이 가드가 알 수 없다. 위 README 루프와 같은 이유로 조용한 추측 대신 시끄러운 실패다.
gs_label() { case "$1" in
  java) echo Java ;; python) echo Python ;; node) echo Node ;; go) echo Go ;;
  dotnet) echo 'C#/.NET' ;; php) echo PHP ;; rust) echo Rust ;; ruby) echo Ruby ;;
  kotlin) echo Kotlin ;; esac; }

rows_seen=0
for L in $DEPLOY_LANGS; do
  _lbl="$(gs_label "$L")"
  # `| <Label> `<version>` |` 의 백틱 안을 뽑는다.
  _row="$(grep -m1 -F "| $_lbl \`" "$gs" || true)"
  [ -n "$_row" ] && rows_seen=$((rows_seen + 1))
  _got="$(printf '%s' "$_row" | sed -n 's/^| [^`]*`\([^`]*\)`.*/\1/p')"
  _want="$(df_published_version "$L")"
  [ -n "$_want" ] || assert_ok false "$L 의 df_published_version 이 비어 있다 — 호환성 표의 기대 버전은 사람이 정해야 한다"
  assert_eq "$_want" "$_got" "호환성 표의 $_lbl 버전이 SSOT와 다르다"
done
# ⚠️ 대조군 — 라벨 표기가 바뀌면 위 루프가 전부 "빈 값 == 빈 값"으로 조용히 통과할 수 있다.
# ⚠️ 메시지 인자를 빠뜨리지 말 것: `assert_eq`는 실패 경로에서 `$3`을 읽는데 이 파일은 `set -u`라
# **실패하는 순간 unbound variable로 죽는다** — 어서션 실패 메시지 대신 셸 오류가 나오고
# `assert_report`에 도달하지 못해 남은 어서션도 안 돈다(변이검증 M4에서 실제로 그렇게 죽었다).
assert_eq "9" "$rows_seen" "호환성 표에서 읽은 언어 행 수가 9가 아니다 — 라벨 표기가 바뀌었나"

# ---- CLAUDE.md 「현재 상태」 표 27셀 ↔ deploy-facts SSOT (#194) ----
#
# 위 claim_at CLAUDE.md 3줄은 게시 *개수* 문장만 본다. 표의 배포명·태그 접두·
# 게시 버전(9×3=27셀)은 한 줄도 없다 — 셀 하나(kotlin 태그 접두)를 바꿔도
# 개수 문장은 그대로라 기존 가드는 통과한다(공허성 실측: 이 루프 없이
# `kotlin-v*` → `kt-v*` 변이 후 이 파일이 97 passed).
#
# 기대값은 전부 SSOT 파생. 하드코딩 금지.
# 미게시(go): df_published_version 은 빈 문자열이고 표는 「미실행」 — 게시되는
# 순간 기대값이 RC 로 바뀌며 미실행 잔존이 실패한다.
claude_status_row() { # $1=언어 라벨. 「현재 상태」 절만 — 뒤의 의존성 표와 섞지 않는다.
  awk '/^## 현재 상태$/{p=1;next} p&&/^## /{exit} p' "$ROOT/CLAUDE.md" \
    | grep -F "| $1 |" | head -n1
}
status_seen=0
for L in $DEPLOY_LANGS; do
  _lbl="$(gs_label "$L")"
  _row="$(claude_status_row "$_lbl")"
  [ -n "$_row" ] && status_seen=$((status_seen + 1))
  _coord="$(df_coordinate "$L")"
  _tag="$(printf "$(df_tag "$L")" '*')"
  _ver="$(df_published_version "$L")"
  assert_contains "$_row" "$_coord" \
    "CLAUDE.md 현재 상태 표의 $_lbl 배포명이 SSOT($_coord)와 다르다"
  assert_contains "$_row" "$_tag" \
    "CLAUDE.md 현재 상태 표의 $_lbl 태그 접두가 SSOT($_tag)와 다르다"
  if [ -n "$_ver" ]; then
    assert_contains "$_row" "$_ver" \
      "CLAUDE.md 현재 상태 표의 $_lbl 게시 버전이 SSOT($_ver)와 다르다"
  else
    assert_contains "$_row" "미실행" \
      "CLAUDE.md 현재 상태 표의 $_lbl 은 미게시인데 「미실행」이 없다"
  fi
done
# ⚠️ 대조군 — 라벨 표기가 바뀌면 위 루프가 빈 행을 9번 비교해 조용히 통과할 수 있다.
assert_eq "9" "$status_seen" \
  "CLAUDE.md 현재 상태 표에서 읽은 언어 행 수가 9가 아니다 — 라벨 표기가 바뀌었나"

# ---- DEPLOY.md `- Install:` 좌표의 **버전 문자열** ↔ df_published_version ----
#
# 같은 축(버전 문자열)인데 위 검사는 getting-started의 호환성 표만 봤다. DEPLOY.md의 설치 좌표
# 아홉 줄 중 버전을 품는 것은 Maven 좌표 둘(java·kotlin)뿐이고, **그 둘 다 게시 후에도 `0.1.0`에
# 멈춰 있었다**(2026-08-11 발견 — java는 08-10, kotlin은 08-11에 각각 `0.1.0-RC1`로 게시됐다).
# 나머지 일곱 줄은 버전 없는 설치 명령(`pip install keycloak-sdk` 등)이라 드리프트할 값이 없다.
# ⚠️ **좌표를 여기서 다시 적지 않는다 — `df_install` 템플릿에서 파생한다.** 처음에는 손으로 옮겨
# 적었는데 go에서 `go get ` 접두를 빠뜨려 **그 어서션이 영원히 성립할 수 없었다**(DEPLOY.md가
# 옳아도 매치가 빈 값이라 실패). 게다가 java 좌표가 kotlin 좌표의 접두라 `grep -m1`이 문서 순서에
# 의존했다. 템플릿의 `%s` 앞부분을 앵커로 쓰면 둘 다 사라진다(java 앵커는 `:`로 끝난다).
_bt='`'      # 백틱 리터럴. 아래 패턴은 전부 완전인용이라야 글롭으로 해석되지 않는다.
_pct='%s'    # printf 자리표시자 리터럴 — 붙여쓰면 셸마다 파싱이 미묘하다(dash 확인).
coords_seen=0
coords_want=0
for L in $DEPLOY_LANGS; do
  _tpl="$(df_install "$L")"
  case "$_tpl" in *"$_pct"*) : ;; *) continue ;; esac   # 버전을 품지 않는 설치 명령은 대조할 값이 없다
  _prefix="${_tpl%%"$_pct"*}"
  _want="$(df_published_version "$L")"
  [ -n "$_want" ] || continue   # 미게시 언어는 대조 대상이 아니다(게시되면 자동으로 편입된다)
  coords_want=$((coords_want + 1))
  # ⚠️ `--` 필수 — 패턴이 `-`로 시작해 grep이 옵션으로 파싱한다(빠뜨리면 매치가 **빈 값**이 되고
  # 아래 대조군이 없으면 "빈 값 == 빈 값"으로 조용히 통과한다).
  _line="$(grep -m1 -F -- "- Install: $_bt$_prefix" "$ROOT/DEPLOY.md" || true)"
  [ -n "$_line" ] && coords_seen=$((coords_seen + 1))
  # sed 대신 파라미터 확장 — 접두에 `/`·`.`·`@`가 섞여 있어 정규식으로 넘기면 이스케이프가 필요하고,
  # 그 이스케이프를 빠뜨리는 것이 바로 위 사고와 같은 부류다.
  _rest="${_line#"- Install: $_bt$_prefix"}"
  _got="${_rest%%"$_bt"*}"
  assert_eq "$_want" "$_got" \
    "DEPLOY.md 의 $L 설치 좌표 버전이 게시 SSOT와 다르다(기대 줄: - Install: $_bt$(printf "$_tpl" "$_want")$_bt)"
done
# ⚠️ 대조군 — 좌표 표기가 바뀌면 위 루프가 "빈 값 == 빈 값"이 아니라 아예 돌지 않아 조용히 통과한다.
# ⚠️ **기대 개수를 하드코딩하지 않는다.** 이전 판은 `2`(java·kotlin)를 박아 두었는데, go가 게시되면
# 실제 기대값은 3인데도 go 줄을 **못 찾은 채** `coords_seen`이 2에 머물러 이 대조군이 통과했다 —
# 대조군이 눈을 감은 채 초록이었다. 그래서 기대값도 SSOT에서 파생한다.
# ⚠️ 다만 파생값끼리의 비교는 **둘 다 0이면 공허하게 통과**한다(루프가 아예 안 돌아도 0==0).
# 하드코딩된 `2`가 우연히 갖고 있던 유일한 미덕이 그 비공허성이었으므로 바닥값으로 분리해 남긴다 —
# java·kotlin은 이미 게시됐고 이 수는 줄어들 수 없다.
assert_ok test "$coords_want" -ge 2
assert_eq "$coords_want" "$coords_seen" \
  "DEPLOY.md 에서 읽은 버전-보유 설치 좌표 수($coords_seen)가 SSOT 파생 기대값($coords_want)과 다르다 — 좌표 표기가 바뀌었나"

# ---- getting-started **본문 설치 절**의 버전 문자열 ↔ df_published_version ----
#
# ⚠️ 위 호환성 표 검사는 **표만** 본다. 그런데 소비자가 실제로 복사하는 것은 언어별 본문의 설치
# 명령이다 — 표를 고치고 본문을 남겨도 통과했다(2026-08-13 재검토가 확인한 C1의 남은 절반).
#
# ⚠️ **`### 3) Installation …` 하위절만 본다.** 같은 언어의 `### 2) Local installation (development)`
# 에는 `0.1.0-SNAPSHOT`(java)·`publishToMavenLocal`로 만든 jar 이름(kotlin)이 정당하게 들어 있어
# 구분 없이 검사하면 오탐이 난다 — 소비자 복사 자리와 로컬 빌드 예제는 다른 것이다.
# ⚠️ go의 절 제목은 게시 전 `### 3) Installation after release (future)`였고 기대값이 "첫 태그
# 버전" 예측이었다. 게시 후에는 자매 언어와 같은 `### 3) Installation from …` 형태가 됐고
# 기대값도 `df_published_version go`(실제 게시 버전)로 자동 전환됐다 — 접두가 같아 이 루프는
# 두 형태를 모두 집는다.
gs_head() { case "$1" in
  java) echo '## Java' ;; python) echo '## Python' ;; node) echo '## Node.js / TypeScript' ;;
  go) echo '## Go' ;; dotnet) echo '## C# / .NET' ;; php) echo '## PHP' ;; rust) echo '## Rust' ;;
  ruby) echo '## Ruby' ;; kotlin) echo '## Kotlin' ;; esac; }

body_seen=0
for L in $DEPLOY_LANGS; do
  _h="$(gs_head "$L")"
  _want="$(df_published_version "$L")"
  if [ -z "$_want" ]; then
    assert_ok false "$L 의 df_published_version 이 비어 있다 — getting-started 설치 절 기대 버전은 사람이 정해야 한다"
    continue
  fi
  _vers="$(awk -v h="$_h" '
    $0 == h { inlang = 1; next }
    /^## / { inlang = 0 }
    inlang && /^### / { ins = ($0 ~ /^### 3\) Installation/) ? 1 : 0 }
    /^```/ { f = !f; next }
    inlang && ins && f { print }
  ' "$gs" | grep -oE '0\.1\.0[A-Za-z0-9.-]*' | sort -u || true)"
  [ -n "$_vers" ] || continue   # 설치 명령에 버전을 안 쓰는 언어(node·rust)는 대조할 값이 없다
  body_seen=$((body_seen + 1))
  _bad="$(printf '%s\n' "$_vers" | grep -Fxv "$_want" || true)"
  assert_eq "" "$_bad" \
    "$L 의 getting-started 설치 절 코드펜스에 게시 SSOT($_want)와 다른 버전이 있다 — 소비자가 없는 좌표를 복사한다"
done
# ⚠️ 대조군 — H2 표기가 바뀌면 위 루프가 전부 `continue`로 빠져 **한 건도 안 돌고 통과**한다.
assert_ok test "$body_seen" -ge 6

assert_report
