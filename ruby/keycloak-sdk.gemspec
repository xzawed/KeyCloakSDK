# frozen_string_literal: true

require_relative "lib/keycloak_sdk/version"

Gem::Specification.new do |spec|
  spec.name        = "keycloak-sdk"
  spec.version     = KeycloakSdk::VERSION
  spec.authors     = ["xzawed"]
  spec.email       = ["xzawed31@gmail.com"]
  spec.summary     = "Polyglot Keycloak SDK for Ruby — auth (OIDC/OAuth2) + Admin REST, hardened JWT validation"
  spec.description = "Idiomatic Ruby facade over rack-oauth2 (auth) and the Keycloak Admin REST API, " \
                     "with a self-hardened JWT validator. Isomorphic to the Java/Python/Node/Go/C#/PHP/Rust SDKs."
  # 모노레포 루트. 아래 링크 중 **저장소 정체성으로 파싱되는 것**은 전부 이 값을 그대로 쓴다.
  repo_root = "https://github.com/xzawed/KeyCloakSDK"

  # `homepage`는 표시용이라 ruby/를 가리켜도 안전하다 — 소비자가 rubygems.org에서 링크를 눌렀을 때
  # 9개 언어 README가 아니라 ruby/README.md에 닿는다.
  spec.homepage    = "#{repo_root}/tree/main/ruby"
  spec.license     = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"

  # ⚠️ `source_code_uri`에는 `/tree/main/ruby`를 넣지 않는다 — OpenSSF Scorecard의 `--rubygems`
  # 경로가 gem을 저장소로 해석할 때 이 필드만 보고, 그 URL 파서는 `owner/repo` 2조각을 기대한다
  # (`/tree/v.../activerecord` 같은 값은 repo="rails/tree/v.../activerecord"로 깨진다).
  # RubyGems 자체는 http(s) 정규식만 검사하므로 통과하지만, 조용히 깨지는 쪽이 더 나쁘다.
  # ⚠️ changelog/bug_tracker도 반드시 repo_root 기준이어야 한다 — homepage에서 파생시키면
  # `.../tree/main/ruby/releases`(404)가 된다.
  # ⚠️ 이전에는 homepage_uri와 source_code_uri가 **같은 값**이라 `gem build`가
  # "Only the first one will be shown on rubygems.org"를 경고했다(실측) — 둘을 갈라 해소됐다.
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => repo_root,
    "changelog_uri" => "#{repo_root}/releases",
    "bug_tracker_uri" => "#{repo_root}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "jwt", "~> 3.2"
  spec.add_dependency "rack-oauth2", "~> 2.3"
end
