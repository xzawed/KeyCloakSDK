import importlib.metadata

import keycloak_sdk


def test_version_matches_installed_distribution_metadata():
    # 한때 이 테스트는 "0.1.0" 문자열 비교였다 — pyproject가 0.1.0rc1로 범프됐을 때
    # 하드코딩된 __version__과 함께 초록으로 남아, 게시된 휠이 자신을 잘못된 버전으로
    # 보고하는 것을 그대로 통과시켰다(실배포 검증에서 발견). 진실 원천은 배포
    # 메타데이터 하나뿐이므로 그 일치만 고정한다 — 상수를 다시 박으면 여기가 잡는다.
    assert keycloak_sdk.__version__ == importlib.metadata.version("keycloak-sdk")


def test_version_falls_back_when_distribution_metadata_is_absent(monkeypatch):
    # 미설치 소스트리 임포트(메타데이터 부재) 경로 — 실패 대신 식별 가능한 폴백을 쓴다.
    def _raise(name: str) -> str:
        raise importlib.metadata.PackageNotFoundError(name)

    monkeypatch.setattr(importlib.metadata, "version", _raise)
    assert keycloak_sdk._detect_version() == "0.0.0+source"
