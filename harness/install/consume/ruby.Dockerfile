# 설치 검증용 소비 이미지(ruby) — harness/ruby(SDK 소스 트리) 접근 없이, 정적 gem repo(gemserver)에
# 게시된 `keycloak-sdk@0.1.0`을 레지스트리 설치로 조립한다. harness/apps/ruby/app.rb와
# ruby/examples/quickstart.rb는 무변경으로 그대로 재사용한다(빌드 컨텍스트 = 리포지토리 루트 —
# COPY 경로 때문). 둘 다 `require "keycloak_sdk"`만 쓰고 Bundler/Gemfile에 의존하지 않으므로
# (RubyGems가 설치된 gem을 자동 활성화) 소스 경로 의존(path: "/src/ruby")이던 harness/apps/ruby/Gemfile은
# 이 이미지에서 아예 필요 없다 — gem install로 설치한 것과 동작이 동형이다.
#
# ⚠️ 설계: install(gemserver)·quickstart 스모크(keycloak)·app boot는 전부 **런타임**(엔트리포인트
# run.sh)에 install-net에서 수행한다(node 참조 구현과 동형 — BuildKit이 build-time custom --network을
# 지원하지 않으므로 기본 빌더로 빌드되도록, 그리고 app-boot/conformance와 동일한 install-net 서비스명
# 해석 경로를 재사용하려는 의도). 상태(installed/quickstartOk)는 호스트 마운트 `/status`의 마커
# 파일로 회수한다 — 컨테이너 생존 여부와 무관하게 오케스트레이터가 읽는다.
#
# build-base/git/openssl-dev/yaml-dev: keycloak-sdk의 전이 의존성(activesupport→bigdecimal/json,
# rack-oauth2→json-jwt→bindata 등)이 끌고 오는 네이티브 확장 컴파일용 — harness/apps/ruby/Dockerfile과
# 동일 패키지 목록(빌드타임 apk, 일반 인터넷 — install-net과 무관).
FROM ruby:3.4-alpine AS app
RUN apk add --no-cache build-base git openssl-dev yaml-dev
WORKDIR /app

COPY harness/apps/ruby/app.rb ./app.rb
COPY ruby/examples/quickstart.rb ./quickstart.rb
COPY harness/install/consume/ruby-run.sh ./run.sh

EXPOSE 8090
# 런타임 엔트리포인트: install → quickstart 스모크 → app boot(전부 install-net에서).
CMD ["sh", "/app/run.sh"]
