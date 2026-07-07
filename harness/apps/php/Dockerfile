# build context = repo root (docker-compose.yml의 context: ..)
FROM php:8.3-alpine

# git: composer path-repo(모노레포 PHP SDK, /src/php)의 버전 감지에 필요.
# $PHPIZE_DEPS + *-dev: curl/mbstring/opcache 네이티브 확장 컴파일 툴체인.
# curl: Guzzle(SDK·league/oauth2-client·ROPC 앱-로컬 POST)의 기본 HTTP 핸들러.
# mbstring: league/oauth2-client 등 다수 PHP 라이브러리의 관용 요구사항.
RUN apk add --no-cache git $PHPIZE_DEPS curl-dev oniguruma-dev \
    && docker-php-ext-install -j"$(nproc)" curl mbstring opcache \
    && apk del $PHPIZE_DEPS

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# PHP SDK 소스(로컬 path repo 대상) — composer.json의 repositories[0].url: /src/php와 일치해야 한다.
COPY php/ /src/php/

WORKDIR /app
COPY harness/apps/php/composer.json /app/composer.json
RUN composer install --no-dev --no-interaction --no-progress --prefer-dist \
    && composer clear-cache

COPY harness/apps/php/public/ /app/public/

RUN addgroup -g 10001 app && adduser -D -u 10001 -G app app \
    && chown -R app:app /app /src/php
USER app

EXPOSE 8090
CMD ["php", "-S", "0.0.0.0:8090", "-t", "public", "public/index.php"]
