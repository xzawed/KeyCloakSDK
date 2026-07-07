# 정적 gem repo 레지스트리 이미지(ruby 설치·동작 검증 참조 구현) — 두 가지 역할을 겸한다:
#  1) compose.install.yml의 gemserver 서비스(장수명) — 기본 CMD가 webrick으로 /repo를 정적 서빙.
#  2) publish/ruby.sh의 1회성 빌드/게시 도구(CMD를 sh -c로 오버라이드해 gem build + generate_index 실행).
# 같은 이미지를 재사용하는 이유: 두 역할 모두 동일한 두 gem(webrick·rubygems-generate_index)만 있으면
# 충분하고, 이미지를 분리하면 각자 별도로 rubygems.org에 접속해 같은 gem을 두 번 받아야 한다.
#
# rubygems-generate_index: RubyGems 3.5.0에서 코어 커맨드로부터 제거된 레거시 Marshal 인덱스 생성기를
# 플러그인 gem으로 복원한 것(docs/superpowers/specs/2026-07-07-install-recipes-research.md §ruby).
# webrick: Ruby 3.0부터 stdlib에서 un-bundle(비-번들)돼 별도 gem 설치가 필요하다(동일 문서).
FROM ruby:3.4-alpine
RUN gem install --no-document webrick rubygems-generate_index
EXPOSE 8808
# /repo가 비어 있어도(최초 기동, 첫 게시 전) 헬스체크·wait_healthy가 200을 받을 수 있도록 index.html을
# 먼저 보장한다 — WEBrick FileHandler는 디렉터리 요청(`/`) 시 index.html이 있으면 그 내용을 그대로
# 서빙한다. publish/ruby.sh가 실행하는 `gem generate_index`가 이후 이 파일을 자체 콘텐츠로 덮어써도
# 무해하다(둘 다 200 OK) — "레지스트리는 게시 이전에도 healthy여야 한다"는 verdaccio(node)와 동일 요구를
# 충족시키기 위한 부트스트랩이다(verdaccio는 `/-/ping`이 내장돼 있으나 정적 gem repo에는 그런 엔드포인트가
# 없어 직접 만들어 준 것).
CMD ["sh", "-c", "mkdir -p /repo && [ -f /repo/index.html ] || echo 'keycloak-sdk local gem repo' > /repo/index.html; exec ruby -run -e httpd /repo -p 8808 -b 0.0.0.0"]
