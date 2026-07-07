# 설치 검증용 소비 이미지(go 참조 구현) — harness/go(SDK 소스 트리) 접근 없이, publish/go.sh가 합성한
# file GOPROXY(레지스트리 데몬 없음 — /proxy 볼륨)에서 github.com/xzawed/KeyCloakSDK/go@0.1.0을 실제
# 소비자 명령(`go get .../go@v0.1.0`)으로 설치한다. harness/apps/go/main.go는 무변경으로 그대로
# 재사용한다(빌드 컨텍스트 = 리포지토리 루트 — main.go COPY 경로 때문).
#
# ⚠️ 설계: node와 동형 — install(go get)·quickstart 스모크(keycloak)·app boot는 전부 **런타임**
# (엔트리포인트 run.sh)에 install-net에서 수행한다(빌드타임엔 네트워크 의존 단계가 없다 — BuildKit이
# build-time custom --network을 지원하지 않으므로 기본 빌더로 빌드되도록, 그리고 app-boot/conformance와
# 동일한 install-net 서비스명 해석 경로를 재사용하려는 의도). file GOPROXY 디렉터리(/proxy)는 레지스트리
# 컨테이너가 아니라 볼륨이므로 compose 서비스가 없다 — run_lang_go()가 docker run -v로 마운트한다.
# 상태(installed/quickstartOk)는 호스트 마운트 /status의 마커 파일로 회수한다(컨테이너 생존 여부와
# 무관하게 오케스트레이터가 읽는다).
FROM golang:1.25-alpine AS app
WORKDIR /app

# 의존성 없는 최소 go.mod — SDK/gocloak은 런타임에 실제 소비자 명령
# `go get github.com/xzawed/KeyCloakSDK/go@v0.1.0 github.com/Nerzal/gocloak/v13@v13.9.0`로 설치한다(go-run.sh).
RUN printf 'module harness-app-go-installed\n\ngo 1.25\n' > go.mod

COPY harness/install/quickstart/go/main.go ./quickstart/main.go
COPY harness/apps/go/main.go ./main.go
COPY harness/install/consume/go-run.sh ./run.sh

EXPOSE 8090
# 런타임 엔트리포인트: install → quickstart 스모크 → app boot(전부 install-net에서).
CMD ["sh", "/app/run.sh"]
