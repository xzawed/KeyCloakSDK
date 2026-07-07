# 설치 검증용 소비 이미지(python — node 참조 구현 패턴 복제) — harness/python(SDK 소스 트리) 접근
# 없이, pypiserver에 게시된 `keycloak-sdk==0.1.0`을 레지스트리 설치로 조립한다.
# harness/apps/python/main.py는 무변경으로 그대로 재사용한다(빌드 컨텍스트 = 리포지토리 루트 —
# main.py COPY 경로 때문).
#
# ⚠️ 설계: install(pypiserver)·quickstart 스모크(keycloak)·app boot는 전부 **런타임**(엔트리포인트
# run.sh)에 install-net에서 수행한다 — 빌드타임엔 네트워크 의존 단계가 없다(BuildKit이 build-time
# custom `--network`를 지원하지 않으므로 기본 빌더로 빌드되도록, 그리고 app-boot/conformance와 동일한
# install-net 서비스명 해석 경로를 재사용하려는 의도 — node.Dockerfile과 동형 이유). 상태
# (installed/quickstartOk)는 호스트 마운트 `/status`의 마커 파일로 회수한다 — 컨테이너 생존 여부와
# 무관하게 오케스트레이터가 읽는다.
FROM python:3.12-alpine AS app
WORKDIR /app

# SDK/FastAPI 등은 런타임에 실제 소비자 명령
# `pip install "keycloak-sdk==0.1.0" -r requirements.txt --extra-index-url … --trusted-host …`로
# 설치한다(python-run.sh). requirements.txt에는 SDK가 포함되지 않는다(app의 프레임워크 의존만).
COPY harness/apps/python/requirements.txt ./requirements.txt

COPY harness/install/quickstart/python/quickstart.py ./quickstart.py
COPY harness/apps/python/main.py ./main.py
COPY harness/install/consume/python-run.sh ./run.sh

EXPOSE 8090
# 런타임 엔트리포인트: install → quickstart 스모크 → app boot(전부 install-net에서).
CMD ["sh", "/app/run.sh"]
