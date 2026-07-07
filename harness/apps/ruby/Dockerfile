FROM ruby:3.4-alpine
# build-base: 네이티브 gem(예: activesupport 전이의존 bigdecimal, json) 컴파일용 C 툴체인
# openssl-dev/yaml-dev: 표준 Ruby native ext 빌드 요구사항. git: 일부 gem 소스 해석 대비.
RUN apk add --no-cache build-base git openssl-dev yaml-dev
WORKDIR /src/ruby
COPY ruby/ /src/ruby/
WORKDIR /app
COPY harness/apps/ruby/Gemfile /app/
RUN bundle install
COPY harness/apps/ruby/app.rb /app/
RUN addgroup -g 10001 app && adduser -D -u 10001 -G app app \
    && chown -R app:app /app /src/ruby
USER app
EXPOSE 8090
CMD ["bundle", "exec", "ruby", "app.rb"]
