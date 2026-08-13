#!/usr/bin/env bash
# install-verify.sh의 **순수 로직**. Docker 없이 실행 가능하도록 분리했다(계획서 Task B4).
#
# 왜 분리하는가: `install-verify.sh`는 1000줄이 넘고 전부 Docker·네트워크에 묶여 있어서, 그 안의
# 순수한 판단 로직(버전 파생·형식 검증)은 **레그를 통째로 돌리기 전에는 시험할 방법이 없었다**.
# 그런데 그 로직에서 실제로 사고가 났다 — 아래 `ver_for_lang`의 순서 의존성은 야간 실행에서는
# 보이지 않고 **언어를 부분집합으로 돌릴 때만** 나타났다.
#
# ⚠️ 여기 두는 것은 **부작용이 없는 것만**이다. Docker·네트워크·파일시스템을 만지는 함수는 넣지
# 않는다 — 그러면 자가테스트가 다시 Docker를 요구하게 되어 분리한 의미가 사라진다.
#
# ⚠️ **bash 전용이다**(`install-verify.sh`가 bash). 연관배열 `MANIFEST_VER`를 읽으므로 dash에서는
# 돌지 않는다 — 자가테스트도 bash로 돌린다. 이 리포의 다른 셸 가드는 dash 호환이지만 이것은
# 대상 스크립트가 bash라 예외다.
#
# 이 파일은 상태를 갖지 않는다. 아래 함수들은 호출자가 세팅한 전역을 읽는다:
#   PKG_VER_EXPLICIT  1이면 사용자가 --version/env로 명시했다
#   PKG_VER           현재 검증 대상 버전(언어 루프가 덮어쓴다)
#   PKG_VER_DEFAULT   폴백 기준값(루프가 덮어쓰지 않는 원본)
#   MANIFEST_VER      lang → 매니페스트 파생 버전(연관배열)

# validate_pkg_ver — 이 값이 sed 표현식·컨테이너 명령에 삽입돼도 안전한 형태인지 본다.
#
# ⚠️ **성공 시 0, 실패 시 2를 return한다(exit이 아니다).** 예전에는 함수 안에서 `exit 2`를 했는데,
# 그러면 이 로직을 자가테스트에서 부를 수 없다 — 첫 실패 케이스가 테스트 프로세스를 죽인다.
# 호출자가 `|| exit 2`로 같은 동작을 만든다.
#
# 허용 범위는 아홉 레지스트리의 표기를 전부 덮는다: 0.1.0 · 0.1.0rc1(PEP 440) · 0.1.0-rc.1(SemVer)
# · 0.1.0.rc1(RubyGems) · 0.1.0-RC1/0.1.0-SNAPSHOT(Maven).
# 매니페스트 파생 값도 같은 경계를 지난다 — 저장소 파일에서 읽었다고 신뢰되는 것은 아니다.
validate_pkg_ver() { # <값> <출처 라벨> → 0 | 2
  case "$1" in
    *[!0-9A-Za-z.+-]* | -* | *..* )
      echo "PKG_VER='$1'($2) 형식이 허용되지 않는다 — 영숫자·점·하이픈·플러스만 쓸 수 있다." >&2
      echo "  이 값은 sed 표현식과 컨테이너 명령에 삽입되므로 경계에서 막는다(fail-closed)." >&2
      return 2 ;;
  esac
  case "$1" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) echo "PKG_VER='$1'($2)가 X.Y.Z로 시작하지 않는다 — 릴리스 버전이 맞는지 확인하라." >&2; return 2 ;;
  esac
  return 0
}

# ver_for_lang — 이 언어가 검증할 버전.
#
# ⚠️ **폴백은 `$PKG_VER`가 아니라 `$PKG_VER_DEFAULT`를 읽는다.** 언어 루프가
# `PKG_VER="$(ver_for_lang "$L")"`로 전역을 덮어쓰므로, 폴백이 그 전역을 읽으면 **직전 언어의
# 버전이 다음 언어로 샌다**. 실측(2026-08-11): `./install-verify.sh java kotlin ruby php go`에서
# ruby(0.1.0.rc1) 다음의 php가 0.1.0.rc1로 검증됐고, go는 `go/v0.1.0.rc1`이 유효한 Go semver가
# 아니라 publish에서 죽었다. 기본 순서(go가 첫 번째)에서는 안 물려 **야간은 초록이었다** —
# 언어를 부분집합으로 돌릴 때만 나타나는 순서 의존성이다. `test-install-verify.sh`가 고정한다.
ver_for_lang() { # <lang> → 이 언어가 검증할 버전(stdout)
  if [ "$PKG_VER_EXPLICIT" -eq 1 ]; then echo "$PKG_VER"; return; fi
  case "$1" in
    # 매니페스트가 산출물 버전을 결정하는 여섯 언어 — 다른 버전을 기대하면 publish에서 반드시 죽는다.
    python|node|rust|ruby|kotlin|dotnet)
      if [ -n "${MANIFEST_VER[$1]:-}" ]; then echo "${MANIFEST_VER[$1]}"; return; fi ;;
  esac
  # go·php(태그 SSOT)·java(versions:set 주입) — publish→consume 자기완결이라 기본값.
  echo "$PKG_VER_DEFAULT"
}
