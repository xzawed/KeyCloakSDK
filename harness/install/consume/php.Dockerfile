# 설치 검증용 소비 이미지(php) — harness/php(SDK 소스 트리) 접근 없이, Satis(satis-web)에 게시된
# `xzawed/keycloak-sdk@0.1.0`을 레지스트리 설치로 조립한다. harness/apps/php/public/index.php는
# 무변경으로 그대로 재사용한다(빌드 컨텍스트 = 리포지토리 루트 — index.php COPY 경로 때문).
#
# ⚠️ 설계: install(satis-web)·quickstart 스모크(keycloak)·app boot는 전부 **런타임**(엔트리포인트
# run.sh)에 install-net에서 수행한다(node 참조 구현과 동형 — satis-web은 install-net 서비스명으로만
# 해석 가능하므로 빌드타임 커스텀 --network을 요구하지 않는 기본 빌더로 이미지를 빌드할 수 있다).
# `apk add`(PHP 런타임)는 Alpine 기본 패키지 미러(기본 브리지 네트워크)만 필요하므로 예외적으로
# 빌드타임에 수행한다 — install-net 레지스트리 의존이 아니라 OS 베이스 레이어 구성이기 때문이다.
#
# ⚠️ harness/apps/php/Dockerfile(공식 php:8.3-alpine + docker-php-ext-install 소스컴파일)과 달리,
# 이 소비 이미지는 Alpine 자체의 사전빌드 php83 apk 패키지를 쓴다(컴파일 툴체인 불요·더 가볍고 빠름 —
# 부록 php절 게차: "런타임 이미지엔 apk add php83-openssl php83-curl php83-mbstring php83-sodium").
FROM alpine:3.21 AS app
WORKDIR /app

RUN apk add --no-cache \
      php83 php83-ctype php83-curl php83-dom php83-fileinfo php83-iconv php83-json \
      php83-mbstring php83-openssl php83-phar php83-session php83-simplexml php83-sodium \
      php83-tokenizer php83-xml php83-xmlwriter \
    && ln -sf /usr/bin/php83 /usr/bin/php

# composer 바이너리 자체는 official composer 이미지에서 그대로 가져온다(harness/apps/php/Dockerfile과
# 동일 관용) — php83 apk 패키지 위에서도 phar로 그대로 동작한다(런타임에 필요한 확장은 위에서 이미 설치).
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# 의존성 최소 매니페스트(slim 프레임워크만 선언) — xzawed/keycloak-sdk는 런타임에 실제 소비자 명령
# `composer require xzawed/keycloak-sdk:^0.1`로 추가 설치한다(php-run.sh). node 참조 구현의
# "빈 package.json + npm install <pkg>@<ver>"과 동형 — 설치 대상 SDK 자체는 빌드타임에 선언하지 않는다.
RUN printf '%s' '{"name":"harness/app-php-installed","type":"project","require":{"php":"^8.3","slim/slim":"^4","slim/psr7":"^1"},"minimum-stability":"dev","prefer-stable":true,"config":{"sort-packages":true,"allow-plugins":{"php-http/discovery":false}}}' > composer.json

# quickstart 스모크: php/examples/quickstart.php를 무변경 재사용(신설 불요 — 이미 존재).
# `__DIR__ . '/../vendor/autoload.php'` 상대경로가 성립하도록 원래와 같은 examples/ 하위에 둔다.
COPY php/examples/quickstart.php ./examples/quickstart.php
COPY harness/apps/php/public/ ./public/
COPY harness/install/consume/php-run.sh ./run.sh

EXPOSE 8090
# 런타임 엔트리포인트: install(composer require) → quickstart 스모크 → app boot(전부 install-net에서).
CMD ["sh", "/app/run.sh"]
