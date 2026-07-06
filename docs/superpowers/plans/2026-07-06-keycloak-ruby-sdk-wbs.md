# Keycloak Ruby SDK Implementation Plan (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 8번째 언어 Ruby Keycloak SDK를 다른 7개 언어와 동형(§4 계약)으로 손수 구현 — sync-only, 자체강화 JWT 검증, 단위 + 실제 Keycloak 26.6 docker-CLI 통합테스트, `rubocop`·SimpleCov(라인90/브랜치85) 게이트.

**Architecture:** `ruby/` 단일 gem `keycloak-sdk`(모듈 `KeycloakSdk`). 계층 `config → auth → jwt → admin → client`(동기). auth는 `rack-oauth2` 래핑 + introspect/logout 손수, admin은 gem 없이 `faraday`로 Admin REST 직접 래핑(bearer 미들웨어가 캐싱 `TokenProvider`에서 토큰 소싱), JWT는 `jwt`(ruby-jwt) + 자체 DoS-safe `JwksStore`. 하위 오류(Faraday·ruby-jwt·rack-oauth2)는 경계에서 `KeycloakSdk::*Error` 예외로 변환. **공유 Faraday 커넥션 팩토리**(follow_redirects 미장착=SSRF·타임아웃 주입)를 token_provider·jwks·admin·introspect/logout에 사용.

**Tech Stack:** Ruby **3.2+**(dev 3.4.x·edition 무관) · `jwt` ~> 3.2 · `rack-oauth2` ~> 2.3 · `faraday` ~> 2.0 · dev: `rspec` · `webmock` · `simplecov` · `rubocop`+`rubocop-rspec` · `bundler-audit` · stdlib `openssl`(테스트 RSA 키생성).

## Global Constraints

- **Ruby floor `>= 3.2`**(gemspec `required_ruby_version`) · 로컬 dev **3.4.x** 포터블 @ `C:\Users\dirtc\tools\ruby`(리포 미커밋). CI 매트릭스 **3.2·3.3·3.4**.
- **gem 이름 `keycloak-sdk`**, **top-level 모듈 `KeycloakSdk`**(require path `keycloak_sdk`) — 기존 `keycloak` gem의 `Keycloak` 모듈 충돌 회피. 라이선스 **Apache-2.0**. gemspec `metadata["rubygems_mfa_required"] = "true"`.
- **동기 전용(sync-only)** — async 금지. 예외 관용(`raise`/`rescue`).
- **§4 결합 규칙**: `admin`은 `auth` 비의존 — `TokenProvider` 덕 인터페이스(`#access_token → String`)가 유일 접착제. admin은 **캐싱 `ClientCredentialsTokenProvider`** 소비(무캐시 `AuthClient` 직접 주입 금지).
- **JWT 자체강화(보안 핵심)**: `algorithms: ["RS256"]`(none/confusion 구조적 거부·수동 헤더 pre-gate 불요)·`iss` 정확·`aud` 포함·`required_claims: ["exp","iss","aud"]`·`verify_not_before: true`·`leeway: config.clock_skew`(기본 30)·DoS-safe JWKS(위조 서명 재조회 안 함·미해결 kid만·rate-limit gate는 재조회 결정 시점 stamp·single-flight).
- **마스킹**: `Config`·`TokenSet`은 `inspect` 오버라이드로 secret/token을 `"***"`(완전 불투명). 단위 강제.
- **SSRF/TLS/타임아웃**: Faraday에 follow_redirects 미장착 · https 검증 기본 on(http는 로컬만) · connect/read 타임아웃 주입.
- **커버리지 게이트**: SimpleCov 라인 ≥90/브랜치 ≥85, `add_filter`로 `auth_client.rb`·`admin/`·`client.rb`(네트워크 경계) omit.
- **테스트**: 네트워크는 `webmock`으로 목킹(실네트워크 금지) · JWT는 stdlib openssl RSA 키쌍으로 실제 서명. 통합은 `:integration` tag(docker-CLI, 단위는 Docker-free).
- **커밋**: 각 태스크 끝 커밋. 메시지 한국어 관용(`feat(ruby):`/`test(ruby):`/`chore(ruby):`). 브랜치 `feature/ruby-sdk`.

### 확정 라이브러리 API (딥리서치 검증 — 아래 코드 근거)

- **ruby-jwt 3.2**: `JWT.decode(token, key=nil, verify=true, options)`. `options[:algorithms]=["RS256"]`가 `verify_algo`에서 헤더 alg∉allowlist를 서명검증·키조회 **前** `JWT::IncorrectAlgorithm` raise(none/confusion 구조적 차단). `options[:jwks]`=**lambda** `->(opts){...}`; 초기 호출 `{kid: kid}`, 미해결 시 `{invalidate: true, kid_not_found: true, kid: kid}`; 반환값은 `JWT::JWK::Set.new`가 받는 형태(Keycloak `/certs`의 `{"keys"=>[...]}` 해시 그대로 OK). `KeyFinder`는 decode마다 재생성→캐시는 loader 밖 공유 스토어에. 반환 `[payload_hash, header_hash]`. 오류: `JWT::IncorrectAlgorithm`·`JWT::VerificationError`·`JWT::ExpiredSignature`·`JWT::ImmatureSignature`·`JWT::InvalidIssuerError`·`JWT::InvalidAudError`·`JWT::MissingRequiredClaim`(전부 `JWT::DecodeError` 하위).
- **rack-oauth2 2.3**: `Rack::OAuth2::Client.new(identifier:, secret:, authorization_endpoint:, token_endpoint:)`. `#authorization_uri(params)`=authz URL(임의 params passthrough → `code_challenge:`/`code_challenge_method: :S256`/`state:`/`scope:`/`nonce:`). 그랜트: `client.authorization_code = code` 후 `client.access_token!(code_verifier: v)`; `client.refresh_token = rt` 후 `client.access_token!`; client_credentials는 기본 그랜트라 `client.access_token!(:client_credentials)`. `access_token!`은 `Rack::OAuth2::AccessToken::Bearer`(`.access_token`·`.refresh_token`·`.id_token`·`.expires_in`·`.raw_attributes`) 반환 또는 오류 시 `Rack::OAuth2::Client::Error`(`.message`·`.error`) raise. 전역 타임아웃: `Rack::OAuth2.http_config { |f| f.options.timeout=..; f.options.open_timeout=.. }`. **introspection/logout은 미커버 → Faraday 손수.**
- **Faraday 2**: `Faraday.new(url:, request: {timeout:, open_timeout:}) { |f| f.request :url_encoded; f.response :json; f.adapter :net_http }`. 리다이렉트는 `faraday-follow_redirects` 미들웨어 **미장착 시 미추종**(SSRF 하드닝). 커스텀 미들웨어 `Faraday::Middleware` 상속 `on_request`. 오류: `Faraday::TimeoutError`·`Faraday::ConnectionFailed`. 응답 `resp.status`·`resp.body`·`resp.headers`.
- **Data.define**(Ruby 3.2+): `T = Data.define(:a,:b) do def m; end end` → 불변 값객체, 키워드/위치 생성, `#with`. `inspect` 오버라이드 가능.

---

### Task 1: 스캐폴딩 (ruby/ · gemspec · Gemfile · rubocop · spec_helper)

**Files:**
- Create: `ruby/keycloak-sdk.gemspec` · `ruby/Gemfile` · `ruby/Rakefile` · `ruby/.rubocop.yml` · `ruby/.gitignore`
- Create: `ruby/lib/keycloak_sdk.rb` · `ruby/lib/keycloak_sdk/version.rb`
- Create: `ruby/spec/spec_helper.rb`
- Test: `ruby/spec/unit/version_spec.rb`

**Interfaces:**
- Produces: `KeycloakSdk::VERSION` (String). `require "keycloak_sdk"` 배럴. `spec/spec_helper.rb`가 SimpleCov(90/85·경계 filter) + WebMock를 초기화.

- [ ] **Step 1: `ruby/keycloak-sdk.gemspec` 작성**

```ruby
# frozen_string_literal: true

require_relative "lib/keycloak_sdk/version"

Gem::Specification.new do |spec|
  spec.name        = "keycloak-sdk"
  spec.version     = KeycloakSdk::VERSION
  spec.authors     = ["xzawed"]
  spec.summary     = "Polyglot Keycloak SDK for Ruby — auth (OIDC/OAuth2) + Admin REST, hardened JWT validation"
  spec.description = "Idiomatic Ruby facade over rack-oauth2 (auth) and the Keycloak Admin REST API, " \
                     "with a self-hardened JWT validator. Isomorphic to the Java/Python/Node/Go/C#/PHP/Rust SDKs."
  spec.homepage    = "https://github.com/xzawed/KeyCloakSDK"
  spec.license     = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "jwt", "~> 3.2"
  spec.add_dependency "rack-oauth2", "~> 2.3"
end
```

- [ ] **Step 2: `ruby/lib/keycloak_sdk/version.rb`**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  VERSION = "0.1.0"
end
```

- [ ] **Step 3: `ruby/lib/keycloak_sdk.rb` (배럴 — 스텁, 이후 태스크가 require 추가)**

```ruby
# frozen_string_literal: true

require_relative "keycloak_sdk/version"

# Polyglot Keycloak SDK for Ruby.
# 이후 태스크에서 아래에 require를 추가한다:
#   require_relative "keycloak_sdk/masking"
#   require_relative "keycloak_sdk/errors"
#   require_relative "keycloak_sdk/config"
#   ... (tokens, oidc_endpoints, token_provider, jwks_store, jwt_validator, auth_client, admin/*, client)
module KeycloakSdk
end
```

- [ ] **Step 4: `ruby/Gemfile` · `ruby/Rakefile` · `ruby/.rubocop.yml` · `ruby/.gitignore`**

`ruby/Gemfile`:
```ruby
# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "bundler-audit", "~> 0.9"
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.60"
  gem "rubocop-rspec", "~> 3.0"
  gem "simplecov", "~> 0.22"
  gem "webmock", "~> 3.23"
end
```

`ruby/Rakefile`:
```ruby
# frozen_string_literal: true

require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = "--tag ~integration"
end

RuboCop::RakeTask.new

task default: %i[rubocop spec]
```

`ruby/.rubocop.yml`:
```yaml
require:
  - rubocop-rspec

AllCops:
  TargetRubyVersion: 3.2
  NewCops: enable
  Exclude:
    - "vendor/**/*"
    - "examples/**/*"

Metrics/MethodLength:
  Max: 25
Metrics/AbcSize:
  Max: 25
Metrics/BlockLength:
  Exclude:
    - "spec/**/*"
    - "*.gemspec"
Style/Documentation:
  Enabled: false
RSpec/ExampleLength:
  Max: 20
RSpec/MultipleExpectations:
  Max: 8
```

`ruby/.gitignore`:
```
/.bundle/
/vendor/bundle/
/coverage/
/pkg/
Gemfile.lock
*.gem
```

- [ ] **Step 5: `ruby/spec/spec_helper.rb` (SimpleCov 먼저, 그다음 SDK require)**

```ruby
# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter %r{/spec/}
  add_filter "lib/keycloak_sdk/version.rb"
  # 네트워크 경계(통합테스트로 검증) — 커버리지 게이트에서 omit
  add_filter "lib/keycloak_sdk/auth_client.rb"
  add_filter %r{lib/keycloak_sdk/admin/}
  add_filter "lib/keycloak_sdk/client.rb"
  minimum_coverage line: 90, branch: 85
end

require "webmock/rspec"
require "keycloak_sdk"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.filter_run_excluding(:integration) unless ENV["RUN_INTEGRATION"]
  WebMock.disable_net_connect!(allow_localhost: false)
end
```

- [ ] **Step 6: `ruby/spec/unit/version_spec.rb` (failing test)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk do
  it "exposes a semver VERSION" do
    expect(KeycloakSdk::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
```

- [ ] **Step 7: 설치 + 실행**

Run(포터블 Ruby 프리픽스 사용):
```bash
export PATH="/c/Users/dirtc/tools/ruby/bin:$PATH"
cd ruby && bundle install && bundle exec rspec spec/unit/version_spec.rb
```
Expected: 1 example, 0 failures. (SimpleCov 커버리지 경고는 파일이 거의 없어 무시 — 이후 태스크에서 로직 추가되며 게이트 유효화. 필요 시 이 시점엔 `minimum_coverage`를 임시로 낮추지 말고 그대로 두되, 단일 파일 실행이라 게이트가 전체를 보지 않음.)

> ⚠️ 포터블 Ruby 설치는 Task 0(툴체인)에서 선행한다 — 본 태스크 착수 전 `ruby -v`가 3.4.x를 반환해야 한다. 미설치 시 구현자는 중단하고 사용자에게 알린다(사용자가 설치 담당).

- [ ] **Step 8: Commit**

```bash
git add ruby/
git commit -m "chore(ruby): 스캐폴딩 — gemspec·Gemfile·rubocop·spec_helper(SimpleCov 90/85+WebMock)·version"
```

---

### Task 2: errors.rb + masking.rb (예외 계층 + 마스킹)

**Files:**
- Create: `ruby/lib/keycloak_sdk/masking.rb` · `ruby/lib/keycloak_sdk/errors.rb`
- Modify: `ruby/lib/keycloak_sdk.rb` (require 추가)
- Test: `ruby/spec/unit/errors_spec.rb` · `ruby/spec/unit/masking_spec.rb`

**Interfaces:**
- Produces:
  - `KeycloakSdk::Masking.mask(secret) → String` (nil→nil, else `"***"`).
  - `KeycloakSdk::Error < StandardError`. 하위: `ConfigError`, `AuthError`(`#oauth_error` attr), `TransportError`, `TokenValidationError`, `AdminError`(`#status` attr) → `NotFoundError`/`ConflictError`/`ForbiddenError` < `AdminError`.
  - `AdminError.from_status(status, message)` → status에 따라 NotFound/Conflict/Forbidden/AdminError 인스턴스 반환(admin 경계 변환기가 사용).

- [ ] **Step 1: `spec/unit/masking_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Masking do
  it "masks a non-nil secret fully opaque" do
    expect(described_class.mask("super-secret")).to eq("***")
  end

  it "returns nil for nil" do
    expect(described_class.mask(nil)).to be_nil
  end
end
```

- [ ] **Step 2: `spec/unit/errors_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe "KeycloakSdk error hierarchy" do
  it "roots every error at KeycloakSdk::Error < StandardError" do
    expect(KeycloakSdk::Error.ancestors).to include(StandardError)
    [KeycloakSdk::ConfigError, KeycloakSdk::AuthError, KeycloakSdk::TransportError,
     KeycloakSdk::TokenValidationError, KeycloakSdk::AdminError].each do |klass|
      expect(klass.ancestors).to include(KeycloakSdk::Error)
    end
  end

  it "nests admin subtypes under AdminError" do
    [KeycloakSdk::NotFoundError, KeycloakSdk::ConflictError, KeycloakSdk::ForbiddenError].each do |klass|
      expect(klass.ancestors).to include(KeycloakSdk::AdminError)
    end
  end

  it "carries oauth_error on AuthError" do
    err = KeycloakSdk::AuthError.new("bad", oauth_error: "invalid_client")
    expect(err.oauth_error).to eq("invalid_client")
  end

  it "maps status to the right admin subtype via from_status" do
    expect(KeycloakSdk::AdminError.from_status(404, "x")).to be_a(KeycloakSdk::NotFoundError)
    expect(KeycloakSdk::AdminError.from_status(409, "x")).to be_a(KeycloakSdk::ConflictError)
    expect(KeycloakSdk::AdminError.from_status(403, "x")).to be_a(KeycloakSdk::ForbiddenError)
    other = KeycloakSdk::AdminError.from_status(500, "boom")
    expect(other).to be_a(KeycloakSdk::AdminError)
    expect(other.status).to eq(500)
  end
end
```

- [ ] **Step 3: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/masking_spec.rb spec/unit/errors_spec.rb`
Expected: FAIL (`uninitialized constant KeycloakSdk::Masking` 등).

- [ ] **Step 4: `lib/keycloak_sdk/masking.rb` 구현**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  # 완전 불투명 마스킹(접두 노출 없음).
  module Masking
    module_function

    def mask(secret)
      secret.nil? ? nil : "***"
    end
  end
end
```

- [ ] **Step 5: `lib/keycloak_sdk/errors.rb` 구현**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  # 모든 SDK 오류의 루트.
  class Error < StandardError; end

  # 설정 검증 실패.
  class ConfigError < Error; end

  # 인증/토큰 발급 실패(OAuth 오류 코드 보존).
  class AuthError < Error
    attr_reader :oauth_error

    def initialize(message = nil, oauth_error: nil)
      super(message)
      @oauth_error = oauth_error
    end
  end

  # 네트워크 전송 실패(타임아웃/연결거부/DNS).
  class TransportError < Error; end

  # JWT 검증 실패.
  class TokenValidationError < Error; end

  # Admin REST 오류(HTTP status 보존).
  class AdminError < Error
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end

    # status → 적절한 하위 예외 인스턴스.
    def self.from_status(status, message)
      case status
      when 404 then NotFoundError.new(message, status: status)
      when 409 then ConflictError.new(message, status: status)
      when 403 then ForbiddenError.new(message, status: status)
      else AdminError.new(message, status: status)
      end
    end
  end

  class NotFoundError < AdminError; end
  class ConflictError < AdminError; end
  class ForbiddenError < AdminError; end
end
```

- [ ] **Step 6: `lib/keycloak_sdk.rb`에 require 추가**

배럴 파일의 `require_relative "keycloak_sdk/version"` 아래에 추가:
```ruby
require_relative "keycloak_sdk/masking"
require_relative "keycloak_sdk/errors"
```

- [ ] **Step 7: Run — 통과 + 린트**

Run: `cd ruby && bundle exec rspec spec/unit/masking_spec.rb spec/unit/errors_spec.rb && bundle exec rubocop lib/keycloak_sdk/masking.rb lib/keycloak_sdk/errors.rb`
Expected: PASS · rubocop 무경고.

- [ ] **Step 8: Commit**

```bash
git add ruby/lib/keycloak_sdk/masking.rb ruby/lib/keycloak_sdk/errors.rb ruby/lib/keycloak_sdk.rb ruby/spec/unit/masking_spec.rb ruby/spec/unit/errors_spec.rb
git commit -m "feat(ruby): 예외 계층(Error→Config/Auth/Transport/TokenValidation/Admin→NotFound/Conflict/Forbidden) + 마스킹"
```

---

### Task 3: config.rb (Config — 불변·검증·마스킹)

**Files:**
- Create: `ruby/lib/keycloak_sdk/config.rb`
- Modify: `ruby/lib/keycloak_sdk.rb`
- Test: `ruby/spec/unit/config_spec.rb`

**Interfaces:**
- Consumes: `KeycloakSdk::ConfigError`.
- Produces: `KeycloakSdk::Config.new(server_url:, realm:, client_id:, client_secret: nil, scopes: ["openid"], connect_timeout: 10, read_timeout: 10, clock_skew: 30)`. Readers: `server_url` `realm` `client_id` `client_secret` `scopes` `connect_timeout` `read_timeout` `clock_skew`. 후행슬래시 제거. `#inspect`가 `client_secret` 마스킹. 필수값 누락/빈문자 → `ConfigError`. 인스턴스는 `freeze`.

- [ ] **Step 1: `spec/unit/config_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Config do
  def valid(**over)
    described_class.new(
      server_url: "https://kc.example.com/", realm: "demo", client_id: "app",
      client_secret: "sekret", **over
    )
  end

  it "strips a trailing slash from server_url" do
    expect(valid.server_url).to eq("https://kc.example.com")
  end

  it "defaults scopes/timeouts/clock_skew" do
    c = described_class.new(server_url: "https://k", realm: "r", client_id: "c")
    expect(c.scopes).to eq(["openid"])
    expect(c.connect_timeout).to eq(10)
    expect(c.read_timeout).to eq(10)
    expect(c.clock_skew).to eq(30)
    expect(c.client_secret).to be_nil
  end

  it "is frozen and immutable" do
    expect(valid).to be_frozen
  end

  it "masks client_secret in inspect and to_s" do
    s = valid.inspect
    expect(s).to include("***")
    expect(s).not_to include("sekret")
    expect(valid.to_s).not_to include("sekret")
  end

  %i[server_url realm client_id].each do |field|
    it "raises ConfigError when #{field} is missing" do
      expect { valid(field => nil) }.to raise_error(KeycloakSdk::ConfigError)
    end

    it "raises ConfigError when #{field} is blank" do
      expect { valid(field => "  ") }.to raise_error(KeycloakSdk::ConfigError)
    end
  end

  it "rejects a non-positive timeout" do
    expect { valid(connect_timeout: 0) }.to raise_error(KeycloakSdk::ConfigError)
  end
end
```

- [ ] **Step 2: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/config_spec.rb`
Expected: FAIL (`uninitialized constant KeycloakSdk::Config`).

- [ ] **Step 3: `lib/keycloak_sdk/config.rb` 구현**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  # 불변 설정. 생성 시 검증하고 freeze한다. client_secret은 inspect에서 마스킹.
  class Config
    attr_reader :server_url, :realm, :client_id, :client_secret,
                :scopes, :connect_timeout, :read_timeout, :clock_skew

    def initialize(server_url:, realm:, client_id:, client_secret: nil,
                   scopes: ["openid"], connect_timeout: 10, read_timeout: 10, clock_skew: 30)
      @server_url = normalize_required("server_url", server_url).sub(%r{/+\z}, "")
      @realm = normalize_required("realm", realm)
      @client_id = normalize_required("client_id", client_id)
      @client_secret = client_secret
      @scopes = Array(scopes).freeze
      @connect_timeout = positive("connect_timeout", connect_timeout)
      @read_timeout = positive("read_timeout", read_timeout)
      @clock_skew = non_negative("clock_skew", clock_skew)
      freeze
    end

    def inspect
      "#<KeycloakSdk::Config server_url=#{@server_url.inspect} realm=#{@realm.inspect} " \
        "client_id=#{@client_id.inspect} client_secret=#{Masking.mask(@client_secret).inspect} " \
        "scopes=#{@scopes.inspect}>"
    end
    alias to_s inspect

    private

    def normalize_required(name, value)
      raise ConfigError, "#{name} is required" if value.nil?

      str = value.to_s
      raise ConfigError, "#{name} must not be blank" if str.strip.empty?

      str
    end

    def positive(name, value)
      raise ConfigError, "#{name} must be > 0" unless value.is_a?(Numeric) && value.positive?

      value
    end

    def non_negative(name, value)
      raise ConfigError, "#{name} must be >= 0" unless value.is_a?(Numeric) && value >= 0

      value
    end
  end
end
```

- [ ] **Step 4: 배럴 require 추가**

`lib/keycloak_sdk.rb`의 errors require 아래:
```ruby
require_relative "keycloak_sdk/config"
```

- [ ] **Step 5: Run — 통과 + 린트**

Run: `cd ruby && bundle exec rspec spec/unit/config_spec.rb && bundle exec rubocop lib/keycloak_sdk/config.rb`
Expected: PASS · rubocop 무경고.

- [ ] **Step 6: Commit**

```bash
git add ruby/lib/keycloak_sdk/config.rb ruby/lib/keycloak_sdk.rb ruby/spec/unit/config_spec.rb
git commit -m "feat(ruby): Config(불변·검증·후행슬래시 제거·inspect 마스킹·기본값)"
```

---

### Task 4: tokens.rb + oidc_endpoints.rb + http.rb (값타입·엔드포인트·HTTP 팩토리)

**Files:**
- Create: `ruby/lib/keycloak_sdk/tokens.rb` · `ruby/lib/keycloak_sdk/oidc_endpoints.rb` · `ruby/lib/keycloak_sdk/http.rb`
- Modify: `ruby/lib/keycloak_sdk.rb`
- Test: `ruby/spec/unit/tokens_spec.rb` · `ruby/spec/unit/oidc_endpoints_spec.rb` · `ruby/spec/unit/http_spec.rb`

**Interfaces:**
- Produces:
  - `KeycloakSdk::TokenSet = Data.define(:access_token,:token_type,:expires_in,:refresh_token,:id_token,:scope,:expires_at)`; `.from_response(body_hash, received_at:) → TokenSet`; `#expired?(skew: 0, now: Time.now.to_f) → Bool`; `#inspect` 마스킹.
  - `KeycloakSdk::ValidatedToken = Data.define(:subject,:audience,:issuer,:expires_at,:issued_at,:claims)`.
  - `KeycloakSdk::IntrospectionResult = Data.define(:active,:username,:client_id,:claims)`; `.from_response(body_hash)`; `#active? → Bool`.
  - `KeycloakSdk::AuthorizationRequest = Data.define(:url,:state,:code_verifier)`; `#inspect` 마스킹.
  - `KeycloakSdk::OidcEndpoints.new(server_url, realm)` / `.from_config(config)`; readers `issuer authorization token introspection end_session jwks`.
  - `KeycloakSdk::Http.build(config, base_url: nil) { |faraday_builder| ... } → Faraday::Connection` (타임아웃 주입·follow_redirects 미장착·`:net_http` 어댑터 말미 부착).

- [ ] **Step 1: `spec/unit/oidc_endpoints_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::OidcEndpoints do
  subject(:ep) { described_class.new("https://kc.example.com", "demo") }

  it "assembles conventional realm URLs (no network)" do
    expect(ep.issuer).to eq("https://kc.example.com/realms/demo")
    expect(ep.authorization).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/auth")
    expect(ep.token).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/token")
    expect(ep.introspection).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/token/introspect")
    expect(ep.end_session).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/logout")
    expect(ep.jwks).to eq("https://kc.example.com/realms/demo/protocol/openid-connect/certs")
  end
end
```

- [ ] **Step 2: `spec/unit/tokens_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe "KeycloakSdk value types" do
  describe KeycloakSdk::TokenSet do
    let(:body) do
      { "access_token" => "AT", "token_type" => "Bearer", "expires_in" => "300",
        "refresh_token" => "RT", "id_token" => "IT", "scope" => "openid email" }
    end

    it "parses a token response and computes expires_at" do
      ts = described_class.from_response(body, received_at: 1000.0)
      expect(ts.access_token).to eq("AT")
      expect(ts.expires_in).to eq(300)
      expect(ts.expires_at).to eq(1300.0)
    end

    it "computes expired? with skew" do
      ts = described_class.from_response(body, received_at: 1000.0)
      expect(ts.expired?(now: 1290.0)).to be(false)
      expect(ts.expired?(now: 1290.0, skew: 30)).to be(true) # 1290 >= 1300-30
      expect(ts.expired?(now: 1301.0)).to be(true)
    end

    it "masks tokens in inspect" do
      s = described_class.from_response(body, received_at: 0.0).inspect
      expect(s).to include("***")
      expect(s).not_to include("AT")
      expect(s).not_to include("RT")
    end
  end

  describe KeycloakSdk::IntrospectionResult do
    it "parses active and exposes active?" do
      r = described_class.from_response({ "active" => true, "username" => "u", "client_id" => "c" })
      expect(r.active?).to be(true)
      expect(r.username).to eq("u")
    end
  end

  describe KeycloakSdk::AuthorizationRequest do
    it "masks code_verifier in inspect" do
      s = described_class.new(url: "https://x?code_challenge=abc", state: "st", code_verifier: "verysecret").inspect
      expect(s).to include("***")
      expect(s).not_to include("verysecret")
    end
  end
end
```

- [ ] **Step 3: `spec/unit/http_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Http do
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://k", realm: "r", client_id: "c",
                            connect_timeout: 3, read_timeout: 7)
  end

  it "injects timeouts from config" do
    conn = described_class.build(config)
    expect(conn.options.open_timeout).to eq(3)
    expect(conn.options.timeout).to eq(7)
  end

  it "does not install a follow-redirects middleware (SSRF hardening)" do
    conn = described_class.build(config) { |f| f.response :json }
    names = conn.builder.handlers.map(&:name)
    expect(names.join).not_to match(/FollowRedirects/i)
  end
end
```

- [ ] **Step 4: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/tokens_spec.rb spec/unit/oidc_endpoints_spec.rb spec/unit/http_spec.rb`
Expected: FAIL (상수 미정의).

- [ ] **Step 5: `lib/keycloak_sdk/oidc_endpoints.rb` 구현**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  # Keycloak realm의 OIDC 엔드포인트를 규약대로 조립한다(네트워크 없음).
  class OidcEndpoints
    attr_reader :issuer, :authorization, :token, :introspection, :end_session, :jwks

    def initialize(server_url, realm)
      base = "#{server_url}/realms/#{realm}"
      oidc = "#{base}/protocol/openid-connect"
      @issuer = base
      @authorization = "#{oidc}/auth"
      @token = "#{oidc}/token"
      @introspection = "#{oidc}/token/introspect"
      @end_session = "#{oidc}/logout"
      @jwks = "#{oidc}/certs"
      freeze
    end

    def self.from_config(config)
      new(config.server_url, config.realm)
    end
  end
end
```

- [ ] **Step 6: `lib/keycloak_sdk/tokens.rb` 구현**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  # OAuth 토큰 응답의 불변 값타입. access/refresh/id 토큰은 inspect에서 마스킹.
  TokenSet = Data.define(:access_token, :token_type, :expires_in, :refresh_token,
                         :id_token, :scope, :expires_at) do
    def self.from_response(body, received_at: Time.now.to_f)
      expires_in = body["expires_in"] && Integer(body["expires_in"])
      new(
        access_token: body["access_token"],
        token_type: body["token_type"],
        expires_in: expires_in,
        refresh_token: body["refresh_token"],
        id_token: body["id_token"],
        scope: body["scope"],
        expires_at: expires_in ? received_at + expires_in : nil
      )
    end

    def expired?(skew: 0, now: Time.now.to_f)
      return false if expires_at.nil?

      now >= (expires_at - skew)
    end

    def inspect
      "#<KeycloakSdk::TokenSet access_token=\"***\" token_type=#{token_type.inspect} " \
        "expires_in=#{expires_in.inspect} refresh_token=#{refresh_token ? '"***"' : 'nil'} " \
        "id_token=#{id_token ? '"***"' : 'nil'} scope=#{scope.inspect} expires_at=#{expires_at.inspect}>"
    end
    alias_method :to_s, :inspect
  end

  # 검증된 access token의 관심 클레임.
  ValidatedToken = Data.define(:subject, :audience, :issuer, :expires_at, :issued_at, :claims)

  # RFC 7662 introspection 결과.
  IntrospectionResult = Data.define(:active, :username, :client_id, :claims) do
    def self.from_response(body)
      new(active: body["active"] == true, username: body["username"],
          client_id: body["client_id"], claims: body)
    end

    def active?
      active == true
    end
  end

  # authorization-code 흐름 시작 값(PKCE code_verifier 포함·inspect 마스킹).
  AuthorizationRequest = Data.define(:url, :state, :code_verifier) do
    def inspect
      "#<KeycloakSdk::AuthorizationRequest url=#{url.inspect} state=#{state.inspect} code_verifier=\"***\">"
    end
    alias_method :to_s, :inspect
  end
end
```

- [ ] **Step 7: `lib/keycloak_sdk/http.rb` 구현**

```ruby
# frozen_string_literal: true

require "faraday"

module KeycloakSdk
  # 공유 Faraday 커넥션 팩토리. 타임아웃을 config에서 주입하고,
  # follow_redirects 미들웨어를 절대 장착하지 않는다(SSRF 하드닝 — Faraday는 기본 미추종).
  module Http
    module_function

    def build(config, base_url: nil)
      Faraday.new(
        url: base_url,
        request: { timeout: config.read_timeout, open_timeout: config.connect_timeout }
      ) do |f|
        yield f if block_given?
        f.adapter :net_http
      end
    end
  end
end
```

- [ ] **Step 8: 배럴 require 추가**

`lib/keycloak_sdk.rb`의 config require 아래:
```ruby
require_relative "keycloak_sdk/tokens"
require_relative "keycloak_sdk/oidc_endpoints"
require_relative "keycloak_sdk/http"
```

- [ ] **Step 9: Run — 통과 + 린트 + Commit**

Run: `cd ruby && bundle exec rspec spec/unit/tokens_spec.rb spec/unit/oidc_endpoints_spec.rb spec/unit/http_spec.rb && bundle exec rubocop lib/keycloak_sdk/tokens.rb lib/keycloak_sdk/oidc_endpoints.rb lib/keycloak_sdk/http.rb`
Expected: PASS · rubocop 무경고.

```bash
git add ruby/lib/keycloak_sdk/tokens.rb ruby/lib/keycloak_sdk/oidc_endpoints.rb ruby/lib/keycloak_sdk/http.rb ruby/lib/keycloak_sdk.rb ruby/spec/unit/tokens_spec.rb ruby/spec/unit/oidc_endpoints_spec.rb ruby/spec/unit/http_spec.rb
git commit -m "feat(ruby): 값타입(TokenSet/ValidatedToken/IntrospectionResult/AuthorizationRequest·inspect 마스킹) + OidcEndpoints + Http 팩토리(타임아웃·SSRF)"
```

---

### Task 5: token_provider.rb (TokenProvider + ClientCredentialsTokenProvider)

**Files:**
- Create: `ruby/lib/keycloak_sdk/token_provider.rb`
- Modify: `ruby/lib/keycloak_sdk.rb`
- Test: `ruby/spec/unit/token_provider_spec.rb`

**Interfaces:**
- Consumes: `Config`, `OidcEndpoints`, `TokenSet`, `AuthError`, `TransportError`, `Http`.
- Produces:
  - `KeycloakSdk::TokenProvider` (덕 인터페이스 모듈 — `#access_token → String`).
  - `KeycloakSdk::ClientCredentialsTokenProvider.new(config:, http:)`; `#access_token → String`. 만료(스큐 여유) 전 캐시 재사용, `Mutex` single-flight. `http`는 `Http.build(config){|f| f.request :url_encoded; f.response :json}` 로 만든 커넥션(폼 인코딩 + JSON 파싱).

- [ ] **Step 1: `spec/unit/token_provider_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::ClientCredentialsTokenProvider do
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: "svc", client_secret: "sekret", clock_skew: 30)
  end
  let(:http) { KeycloakSdk::Http.build(config) { |f| f.request :url_encoded; f.response :json } }
  let(:token_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/token" }

  subject(:provider) { described_class.new(config: config, http: http) }

  it "fetches a client-credentials token and returns the access_token string" do
    stub = stub_request(:post, token_url)
           .with(body: hash_including("grant_type" => "client_credentials", "client_id" => "svc",
                                       "client_secret" => "sekret", "scope" => "openid"))
           .to_return(status: 200, body: { access_token: "AT1", expires_in: 300, token_type: "Bearer" }.to_json,
                      headers: { "Content-Type" => "application/json" })
    expect(provider.access_token).to eq("AT1")
    expect(stub).to have_been_requested.once
  end

  it "caches the token until near expiry (single network call)" do
    stub = stub_request(:post, token_url)
           .to_return(status: 200, body: { access_token: "AT1", expires_in: 300, token_type: "Bearer" }.to_json,
                      headers: { "Content-Type" => "application/json" })
    3.times { provider.access_token }
    expect(stub).to have_been_requested.once
  end

  it "raises AuthError with oauth_error on 401" do
    stub_request(:post, token_url)
      .to_return(status: 401, body: { error: "invalid_client" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    expect { provider.access_token }.to raise_error(KeycloakSdk::AuthError) { |e| expect(e.oauth_error).to eq("invalid_client") }
  end

  it "raises TransportError on connection failure" do
    stub_request(:post, token_url).to_raise(Faraday::ConnectionFailed.new("refused"))
    expect { provider.access_token }.to raise_error(KeycloakSdk::TransportError)
  end
end
```

- [ ] **Step 2: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/token_provider_spec.rb`
Expected: FAIL (`uninitialized constant`).

- [ ] **Step 3: `lib/keycloak_sdk/token_provider.rb` 구현**

```ruby
# frozen_string_literal: true

require "uri"

module KeycloakSdk
  # 덕 인터페이스: 구현체는 #access_token → String 을 응답한다.
  # admin은 이 인터페이스로만 토큰을 받는다(auth 비의존, §4 결합 규칙).
  module TokenProvider
  end

  # client-credentials 그랜트로 토큰을 발급하고 만료 전까지 캐시한다(Mutex single-flight).
  # admin 파사드가 소비하는 캐싱 provider(무캐시 AuthClient 직접 주입 금지 — §4 캐시 불변식).
  class ClientCredentialsTokenProvider
    include TokenProvider

    def initialize(config:, http:)
      @config = config
      @http = http
      @token_url = OidcEndpoints.from_config(config).token
      @mutex = Mutex.new
      @cached = nil
      @expires_at = 0.0
    end

    def access_token
      @mutex.synchronize do
        now = Time.now.to_f
        return @cached if @cached && now < @expires_at

        ts = request_token
        @cached = ts.access_token
        @expires_at = ts.expires_at ? (ts.expires_at - @config.clock_skew) : (now + 60)
        @cached
      end
    end

    private

    def request_token
      resp = @http.post(@token_url, {
                          grant_type: "client_credentials",
                          client_id: @config.client_id,
                          client_secret: @config.client_secret,
                          scope: @config.scopes.join(" ")
                        })
      unless resp.success?
        oauth = resp.body.is_a?(Hash) ? resp.body["error"] : nil
        raise AuthError.new("client-credentials token request failed: HTTP #{resp.status}", oauth_error: oauth)
      end

      TokenSet.from_response(resp.body, received_at: Time.now.to_f)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "token endpoint transport error: #{e.message}"
    end
  end
end
```

- [ ] **Step 4: 배럴 require 추가**

`lib/keycloak_sdk.rb`의 http require 아래:
```ruby
require_relative "keycloak_sdk/token_provider"
```

- [ ] **Step 5: Run — 통과 + 린트 + Commit**

Run: `cd ruby && bundle exec rspec spec/unit/token_provider_spec.rb && bundle exec rubocop lib/keycloak_sdk/token_provider.rb`
Expected: PASS · rubocop 무경고.

```bash
git add ruby/lib/keycloak_sdk/token_provider.rb ruby/lib/keycloak_sdk.rb ruby/spec/unit/token_provider_spec.rb
git commit -m "feat(ruby): TokenProvider 인터페이스 + ClientCredentialsTokenProvider(캐시·Mutex single-flight·오류변환)"
```

---

### Task 6: jwks_store.rb (DoS-safe JWKS 스토어)

**Files:**
- Create: `ruby/lib/keycloak_sdk/jwks_store.rb`
- Modify: `ruby/lib/keycloak_sdk.rb`
- Test: `ruby/spec/unit/jwks_store_spec.rb`

**Interfaces:**
- Consumes: `TransportError`, `Faraday`.
- Produces: `KeycloakSdk::JwksStore.new(jwks_url:, http:, min_refetch: 10.0)`; `#key_set(force: false) → Hash` (`{"keys"=>[...]}` — ruby-jwt `JWT::JWK::Set.new`가 수용). 캐시 히트=네트워크 0. `force:true`(미해결 kid)에서만 재조회, **rate-limit gate는 재조회 결정 시점 stamp**(cold load는 예산 미소모), `Mutex` single-flight. malformed/transport → `TransportError`.

- [ ] **Step 1: `spec/unit/jwks_store_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::JwksStore do
  let(:config) { KeycloakSdk::Config.new(server_url: "https://k", realm: "r", client_id: "c") }
  let(:http) { KeycloakSdk::Http.build(config) { |f| f.response :json } }
  let(:jwks_url) { "https://k/realms/r/protocol/openid-connect/certs" }
  let(:body) { { keys: [{ kty: "RSA", kid: "k1", n: "AQAB", e: "AQAB" }] }.to_json }

  subject(:store) { described_class.new(jwks_url: jwks_url, http: http, min_refetch: 1000.0) }

  it "fetches once (cold) and caches subsequent non-forced reads" do
    stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                  headers: { "Content-Type" => "application/json" })
    3.times { store.key_set }
    expect(store.key_set["keys"].first["kid"]).to eq("k1")
    expect(stub).to have_been_requested.once
  end

  it "rate-limits forced re-fetches (unresolved kid) within the window" do
    stub = stub_request(:get, jwks_url).to_return(status: 200, body: body,
                                                  headers: { "Content-Type" => "application/json" })
    store.key_set                    # cold load (no stamp)
    store.key_set(force: true)       # 1st forced → allowed → stamp + fetch
    store.key_set(force: true)       # within window → rate-limited → serve stale, no fetch
    expect(stub).to have_been_requested.times(2)
  end

  it "raises TransportError on non-200" do
    stub_request(:get, jwks_url).to_return(status: 500, body: "err")
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "raises TransportError on malformed body" do
    stub_request(:get, jwks_url).to_return(status: 200, body: { nope: 1 }.to_json,
                                           headers: { "Content-Type" => "application/json" })
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end

  it "raises TransportError on connection failure" do
    stub_request(:get, jwks_url).to_raise(Faraday::ConnectionFailed.new("refused"))
    expect { store.key_set }.to raise_error(KeycloakSdk::TransportError)
  end
end
```

- [ ] **Step 2: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/jwks_store_spec.rb`
Expected: FAIL (`uninitialized constant`).

- [ ] **Step 3: `lib/keycloak_sdk/jwks_store.rb` 구현**

```ruby
# frozen_string_literal: true

require "faraday"

module KeycloakSdk
  # DoS-safe JWKS 스토어. Mutex 캐시 + rate-limit + single-flight.
  # 위조 서명(알려진 kid)은 캐시 반환만 하고 재조회를 유발하지 않는다.
  # 미해결 kid(force:true)만 재조회하며, rate-limit gate는 재조회 결정 시점에 stamp한다
  # (성공 아님 — IdP 장애창에서 위조 kid 폭주에도 재조회를 상한한다). Go/Rust/Python 동형.
  class JwksStore
    def initialize(jwks_url:, http:, min_refetch: 10.0)
      @jwks_url = jwks_url
      @http = http
      @min_refetch = min_refetch
      @mutex = Mutex.new
      @cache = nil        # {"keys" => [...]}
      @last_refetch = nil # monotonic seconds
    end

    # ruby-jwt jwks: 로더가 호출. force=true는 미해결 kid 재조회 요청.
    def key_set(force: false)
      @mutex.synchronize do
        return @cache if @cache && !force
        return @cache if @cache && force && !refetch_allowed?

        @last_refetch = monotonic if force # 결정 시점 stamp(cold load는 예산 미소모)
        @cache = fetch
      end
    end

    private

    def refetch_allowed?
      @last_refetch.nil? || (monotonic - @last_refetch) >= @min_refetch
    end

    def fetch
      resp = @http.get(@jwks_url)
      raise TransportError, "JWKS fetch failed: HTTP #{resp.status}" unless resp.success?

      body = resp.body
      raise TransportError, "JWKS response malformed" unless body.is_a?(Hash) && body["keys"].is_a?(Array)

      body
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "JWKS transport error: #{e.message}"
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
```

- [ ] **Step 4: 배럴 require 추가**

`lib/keycloak_sdk.rb`의 token_provider require 아래:
```ruby
require_relative "keycloak_sdk/jwks_store"
```

- [ ] **Step 5: Run — 통과 + 린트 + Commit**

Run: `cd ruby && bundle exec rspec spec/unit/jwks_store_spec.rb && bundle exec rubocop lib/keycloak_sdk/jwks_store.rb`
Expected: PASS · rubocop 무경고.

```bash
git add ruby/lib/keycloak_sdk/jwks_store.rb ruby/lib/keycloak_sdk.rb ruby/spec/unit/jwks_store_spec.rb
git commit -m "feat(ruby): JwksStore — DoS-safe JWKS(Mutex 캐시·미해결 kid만 재조회·rate-limit 결정시점 stamp·single-flight)"
```

---

### Task 7: jwt_validator.rb (JwtValidator — 자체강화, 🔴 보안 핵심)

**Files:**
- Create: `ruby/lib/keycloak_sdk/jwt_validator.rb`
- Modify: `ruby/lib/keycloak_sdk.rb`
- Test: `ruby/spec/unit/jwt_validator_spec.rb`

**Interfaces:**
- Consumes: `Config`, `OidcEndpoints`, `JwksStore`, `ValidatedToken`, `TokenValidationError`.
- Produces: `KeycloakSdk::JwtValidator.new(issuer:, audience:, jwks_store:, clock_skew: 30)` / `.from_config(config:, jwks_store:)`; `#validate(token) → ValidatedToken` (실패 시 `TokenValidationError`).
- 강화 불변식(전부 단위 고정): RS256 핀(none/HS256/무-alg 구조적 거부·헤더 alg를 검증 알고리즘 선택에 미사용) · iss 정확 · aud 포함(문자열/배열) · exp 필수(`required_claims`) · nbf · 클록스큐 · 위조 서명은 JWKS 재조회 미유발(알려진 kid).

> ⚠️ **수동 헤더 pre-gate를 추가하지 말 것.** ruby-jwt는 `algorithms: ["RS256"]`로 검증 前 alg를 거부하므로 pre-gate는 불필요·중복이다(PHP firebase/php-jwt와 발산 — 과잉설계 금지). 이는 의도된 설계다.

- [ ] **Step 1: `spec/unit/jwt_validator_spec.rb` 작성 (RSA 키로 실제 서명 — 강화 불변식 전부, failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"
require "jwt"
require "openssl"

RSpec.describe KeycloakSdk::JwtValidator do
  let(:rsa) { OpenSSL::PKey::RSA.generate(2048) }
  let(:kid) { "test-key-1" }
  let(:issuer) { "https://kc.example.com/realms/demo" }
  let(:audience) { "app" }
  let(:jwks_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/certs" }
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: audience, clock_skew: 30)
  end
  let(:http) { KeycloakSdk::Http.build(config) { |f| f.response :json } }
  let(:jwks_store) { KeycloakSdk::JwksStore.new(jwks_url: jwks_url, http: http) }

  subject(:validator) { described_class.from_config(config: config, jwks_store: jwks_store) }

  def jwk_hash
    JWT::JWK.new(rsa, kid: kid).export # public JWK
  end

  def stub_jwks
    stub_request(:get, jwks_url).to_return(status: 200, body: { keys: [jwk_hash] }.to_json,
                                           headers: { "Content-Type" => "application/json" })
  end

  def sign(claims, key: rsa, alg: "RS256", header: { kid: kid })
    JWT.encode(claims, key, alg, header)
  end

  def base_claims(**over)
    now = Time.now.to_i
    { "sub" => "user-1", "iss" => issuer, "aud" => audience, "exp" => now + 300, "iat" => now }.merge(over.transform_keys(&:to_s))
  end

  before { stub_jwks }

  it "accepts a valid RS256 token and maps claims" do
    vt = validator.validate(sign(base_claims))
    expect(vt).to be_a(KeycloakSdk::ValidatedToken)
    expect(vt.subject).to eq("user-1")
    expect(vt.issuer).to eq(issuer)
    expect(vt.audience).to include(audience)
  end

  it "accepts an array aud containing our client_id" do
    vt = validator.validate(sign(base_claims("aud" => ["other-svc", audience])))
    expect(vt.audience).to include(audience)
  end

  it "rejects alg:none" do
    tok = JWT.encode(base_claims, nil, "none")
    expect { validator.validate(tok) }.to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects alg-confusion (HS256 with public modulus as secret is impossible)" do
    tok = JWT.encode(base_claims, "secret", "HS256", { kid: kid })
    expect { validator.validate(tok) }.to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects a wrong issuer" do
    expect { validator.validate(sign(base_claims("iss" => "https://evil.example"))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects an aud that lacks our client_id" do
    expect { validator.validate(sign(base_claims("aud" => "someone-else"))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects an expired token" do
    expect { validator.validate(sign(base_claims("exp" => Time.now.to_i - 100))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects a token missing exp (required_claims)" do
    claims = base_claims
    claims.delete("exp")
    expect { validator.validate(sign(claims)) }.to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects a not-yet-valid token (nbf in the future)" do
    expect { validator.validate(sign(base_claims("nbf" => Time.now.to_i + 300))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end

  it "rejects a bad signature WITHOUT re-fetching JWKS (known kid)" do
    other = OpenSSL::PKey::RSA.generate(2048)
    tok = sign(base_claims, key: other) # different key, same kid
    expect { validator.validate(tok) }.to raise_error(KeycloakSdk::TokenValidationError)
    expect(a_request(:get, jwks_url)).to have_been_made.once # cold load only, no forged-sig re-fetch
  end

  it "honors clock skew (30s): 20s-expired passes, 40s-expired fails" do
    expect(validator.validate(sign(base_claims("exp" => Time.now.to_i - 20))))
      .to be_a(KeycloakSdk::ValidatedToken)
    expect { validator.validate(sign(base_claims("exp" => Time.now.to_i - 40))) }
      .to raise_error(KeycloakSdk::TokenValidationError)
  end
end
```

- [ ] **Step 2: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/jwt_validator_spec.rb`
Expected: FAIL (`uninitialized constant KeycloakSdk::JwtValidator`).

- [ ] **Step 3: `lib/keycloak_sdk/jwt_validator.rb` 구현**

```ruby
# frozen_string_literal: true

require "jwt"

module KeycloakSdk
  # 자체강화 JWT 검증기. ruby-jwt의 안전하지 않은 기본값을 전부 오버라이드한다:
  # RS256 핀(none/confusion 구조적 거부)·iss 정확·aud 포함·exp 필수·nbf·클록스큐.
  # 키는 DoS-safe JwksStore로 조회한다(위조 서명은 재조회 미유발). 헤더 alg는 검증 알고리즘 선택에 미사용.
  class JwtValidator
    def initialize(issuer:, audience:, jwks_store:, clock_skew: 30)
      @issuer = issuer
      @audience = audience
      @jwks_store = jwks_store
      @clock_skew = clock_skew
    end

    def self.from_config(config:, jwks_store:)
      new(issuer: OidcEndpoints.from_config(config).issuer,
          audience: config.client_id, jwks_store: jwks_store, clock_skew: config.clock_skew)
    end

    def validate(token)
      payload, = JWT.decode(token, nil, true, decode_options)
      to_validated(payload)
    rescue JWT::DecodeError => e
      raise TokenValidationError, "JWT validation failed: #{e.message}"
    end

    private

    def decode_options
      {
        algorithms: ["RS256"],
        jwks: jwks_loader,
        verify_iss: true, iss: @issuer,
        verify_aud: true, aud: @audience,
        verify_expiration: true,
        verify_not_before: true,
        required_claims: %w[exp iss aud],
        leeway: @clock_skew
      }
    end

    # 초기 호출 {kid:}=캐시, 미해결 시 {kid_not_found:true, invalidate:true, kid:}=재조회.
    def jwks_loader
      lambda do |opts|
        force = opts[:kid_not_found] || opts[:invalidate] || false
        @jwks_store.key_set(force: force)
      end
    end

    def to_validated(payload)
      ValidatedToken.new(
        subject: payload["sub"],
        audience: Array(payload["aud"]),
        issuer: payload["iss"],
        expires_at: payload["exp"],
        issued_at: payload["iat"],
        claims: payload
      )
    end
  end
end
```

- [ ] **Step 4: 배럴 require 추가**

`lib/keycloak_sdk.rb`의 jwks_store require 아래:
```ruby
require_relative "keycloak_sdk/jwt_validator"
```

- [ ] **Step 5: Run — 통과 + 린트 + Commit**

Run: `cd ruby && bundle exec rspec spec/unit/jwt_validator_spec.rb && bundle exec rubocop lib/keycloak_sdk/jwt_validator.rb`
Expected: PASS(11 예제) · rubocop 무경고.

> 구현자 주의: `JWT::JWK::Set.new`가 로더의 `{"keys"=>[...]}` 해시를 수용하는지 첫 테스트(valid token)로 확인된다. 만약 `Set.new`가 배열만 받는 버전이면 로더를 `@jwks_store.key_set(force:)["keys"]`로 좁힌다(테스트가 즉시 알려줌).

```bash
git add ruby/lib/keycloak_sdk/jwt_validator.rb ruby/lib/keycloak_sdk.rb ruby/spec/unit/jwt_validator_spec.rb
git commit -m "feat(ruby): JwtValidator 자체강화(RS256핀·none 구조적 거부·iss 정확·aud 포함·exp 필수·nbf·스큐·DoS-safe JWKS) — 보안 핵심"
```

---

### Task 8: auth_client.rb (AuthClient — rack-oauth2 래핑 + introspect/logout 손수)

> **커버리지 경계**: `auth_client.rb`는 SimpleCov `add_filter`로 omit(네트워크 경계). 아래 단위 스펙은 동작 검증용(게이트 미포함)이며, 주 검증은 Task 11 통합테스트다. offline인 `create_authorization_request`는 순수 로직이라 반드시 단위로 고정한다.

**Files:**
- Create: `ruby/lib/keycloak_sdk/auth_client.rb`
- Modify: `ruby/lib/keycloak_sdk.rb`
- Test: `ruby/spec/unit/auth_client_spec.rb`

**Interfaces:**
- Consumes: `Config`, `OidcEndpoints`, `TokenSet`, `IntrospectionResult`, `AuthorizationRequest`, `JwtValidator`, `TokenProvider`, `AuthError`, `TransportError`, `Http`.
- Produces: `KeycloakSdk::AuthClient.new(config:, http:, jwt_validator:)` (`http`=form+json Faraday). 메서드: `#create_authorization_request(redirect_uri:, scopes: nil, state:, nonce: nil) → AuthorizationRequest` · `#exchange_code(code:, code_verifier:, redirect_uri:) → TokenSet` · `#refresh(refresh_token:) → TokenSet` · `#client_credentials_token → TokenSet` · `#access_token → String`(TokenProvider) · `#introspect(token) → IntrospectionResult` · `#logout(refresh_token:) → nil` · `#validate(token) → ValidatedToken`(위임).

- [ ] **Step 1: `spec/unit/auth_client_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::AuthClient do
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: "app", client_secret: "sekret", scopes: %w[openid email])
  end
  let(:http) { KeycloakSdk::Http.build(config) { |f| f.request :url_encoded; f.response :json } }
  let(:jwt_validator) { instance_double(KeycloakSdk::JwtValidator) }
  let(:introspect_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/token/introspect" }
  let(:logout_url) { "https://kc.example.com/realms/demo/protocol/openid-connect/logout" }

  subject(:auth) { described_class.new(config: config, http: http, jwt_validator: jwt_validator) }

  describe "#create_authorization_request (offline, PKCE S256)" do
    it "builds an authorization URL with S256 challenge and returns a masked verifier" do
      req = auth.create_authorization_request(redirect_uri: "https://app/cb", state: "st-123")
      expect(req.url).to include("code_challenge_method=S256")
      expect(req.url).to include("code_challenge=")
      expect(req.url).to include("state=st-123")
      expect(req.state).to eq("st-123")
      expect(req.code_verifier).to be_a(String)
      expect(req.inspect).not_to include(req.code_verifier)
    end
  end

  describe "#introspect" do
    it "posts to the introspection endpoint and parses the result" do
      stub_request(:post, introspect_url)
        .with(body: hash_including("token" => "AT", "client_id" => "app"))
        .to_return(status: 200, body: { active: true, username: "u", client_id: "app" }.to_json,
                   headers: { "Content-Type" => "application/json" })
      r = auth.introspect("AT")
      expect(r.active?).to be(true)
      expect(r.username).to eq("u")
    end

    it "raises TransportError on connection failure" do
      stub_request(:post, introspect_url).to_raise(Faraday::ConnectionFailed.new("x"))
      expect { auth.introspect("AT") }.to raise_error(KeycloakSdk::TransportError)
    end
  end

  describe "#logout" do
    it "posts refresh_token to end_session and returns nil" do
      stub_request(:post, logout_url).with(body: hash_including("refresh_token" => "RT"))
                                     .to_return(status: 204, body: "")
      expect(auth.logout(refresh_token: "RT")).to be_nil
    end
  end

  describe "#validate" do
    it "delegates to the JwtValidator" do
      vt = instance_double(KeycloakSdk::ValidatedToken)
      allow(jwt_validator).to receive(:validate).with("tok").and_return(vt)
      expect(auth.validate("tok")).to be(vt)
    end
  end
end
```

- [ ] **Step 2: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/auth_client_spec.rb`
Expected: FAIL (`uninitialized constant`).

- [ ] **Step 3: `lib/keycloak_sdk/auth_client.rb` 구현**

```ruby
# frozen_string_literal: true

require "rack/oauth2"
require "securerandom"
require "digest"
require "base64"

module KeycloakSdk
  # 인증 파사드. rack-oauth2를 래핑(그랜트·PKCE)하고 introspection(RFC7662)·logout은 Faraday로 손수 수행한다.
  # TokenProvider를 구현하지만(직접 사용용), admin은 캐싱 ClientCredentialsTokenProvider를 별도로 쓴다(§4).
  class AuthClient
    include TokenProvider

    def initialize(config:, http:, jwt_validator:)
      @config = config
      @http = http
      @jwt_validator = jwt_validator
      @endpoints = OidcEndpoints.from_config(config)
    end

    def create_authorization_request(redirect_uri:, scopes: nil, state: SecureRandom.urlsafe_base64(24), nonce: nil)
      verifier = SecureRandom.urlsafe_base64(64)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      params = {
        scope: (scopes || @config.scopes).join(" "),
        state: state,
        code_challenge: challenge,
        code_challenge_method: :S256
      }
      params[:nonce] = nonce if nonce
      url = oauth_client(redirect_uri: redirect_uri).authorization_uri(params)
      AuthorizationRequest.new(url: url.to_s, state: state, code_verifier: verifier)
    end

    def exchange_code(code:, code_verifier:, redirect_uri:)
      client = oauth_client(redirect_uri: redirect_uri)
      client.authorization_code = code
      to_token_set(client.access_token!(code_verifier: code_verifier))
    rescue Rack::OAuth2::Client::Error => e
      raise AuthError.new("authorization_code exchange failed: #{e.message}", oauth_error: e.error.to_s)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "token endpoint transport error: #{e.message}"
    end

    def refresh(refresh_token:)
      client = oauth_client
      client.refresh_token = refresh_token
      to_token_set(client.access_token!)
    rescue Rack::OAuth2::Client::Error => e
      raise AuthError.new("refresh failed: #{e.message}", oauth_error: e.error.to_s)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "token endpoint transport error: #{e.message}"
    end

    def client_credentials_token
      to_token_set(oauth_client.access_token!(:client_credentials))
    rescue Rack::OAuth2::Client::Error => e
      raise AuthError.new("client-credentials failed: #{e.message}", oauth_error: e.error.to_s)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "token endpoint transport error: #{e.message}"
    end

    # TokenProvider 계약(직접 사용용). admin은 캐싱 provider를 별도로 쓴다.
    def access_token
      client_credentials_token.access_token
    end

    def introspect(token)
      resp = @http.post(@endpoints.introspection, {
                          token: token, client_id: @config.client_id, client_secret: @config.client_secret
                        })
      raise AuthError, "introspection failed: HTTP #{resp.status}" unless resp.success?

      IntrospectionResult.from_response(resp.body)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "introspection transport error: #{e.message}"
    end

    def logout(refresh_token:)
      resp = @http.post(@endpoints.end_session, {
                          client_id: @config.client_id, client_secret: @config.client_secret,
                          refresh_token: refresh_token
                        })
      raise AuthError, "logout failed: HTTP #{resp.status}" unless resp.success?

      nil
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise TransportError, "logout transport error: #{e.message}"
    end

    def validate(token)
      @jwt_validator.validate(token)
    end

    private

    def oauth_client(redirect_uri: nil)
      Rack::OAuth2::Client.new(
        identifier: @config.client_id,
        secret: @config.client_secret,
        authorization_endpoint: @endpoints.authorization,
        token_endpoint: @endpoints.token,
        redirect_uri: redirect_uri
      )
    end

    def to_token_set(token)
      raw = token.raw_attributes || {}
      scope = raw[:scope] || raw["scope"]
      TokenSet.new(
        access_token: token.access_token,
        token_type: "Bearer",
        expires_in: token.expires_in,
        refresh_token: token.refresh_token,
        id_token: (token.respond_to?(:id_token) ? token.id_token : nil),
        scope: scope,
        expires_at: token.expires_in ? Time.now.to_f + token.expires_in : nil
      )
    end
  end
end
```

- [ ] **Step 4: 배럴 require 추가 + rack-oauth2 전역 타임아웃**

`lib/keycloak_sdk.rb`의 jwt_validator require 아래:
```ruby
require_relative "keycloak_sdk/auth_client"
```

`lib/keycloak_sdk.rb` 하단(모듈 정의 밖)에 rack-oauth2 전역 HTTP 타임아웃 설정(hung IdP 방지 — Faraday 커넥션은 rack-oauth2가 내부 소유하므로 전역 훅으로 주입):
```ruby
require "rack/oauth2"
Rack::OAuth2.http_config do |options|
  options.open_timeout = 10
  options.timeout = 10
end
```
> 참고: rack-oauth2는 프로세스 전역 http_config를 쓴다. per-Config 타임아웃 미세제어는 불가하므로 보수적 기본(10s)으로 고정한다(introspect/logout은 우리 Faraday라 config 타임아웃 적용).

- [ ] **Step 5: Run — 통과 + 린트 + Commit**

Run: `cd ruby && bundle exec rspec spec/unit/auth_client_spec.rb && bundle exec rubocop lib/keycloak_sdk/auth_client.rb`
Expected: PASS · rubocop 무경고. (커버리지 게이트는 auth_client omit이라 영향 없음.)

```bash
git add ruby/lib/keycloak_sdk/auth_client.rb ruby/lib/keycloak_sdk.rb ruby/spec/unit/auth_client_spec.rb
git commit -m "feat(ruby): AuthClient — rack-oauth2 래핑(그랜트·PKCE S256 손수) + introspect/logout 손수 + validate 위임 + TokenProvider"
```

---

### Task 9: admin/ (AdminClient + 5 리소스 + bearer 미들웨어 + raw)

> **커버리지 경계**: `admin/`는 SimpleCov `add_filter`로 omit. 아래 단위 스펙은 오류 경계 변환 검증용, 전체 CRUD는 Task 11 통합테스트가 실제 KC로 검증한다.

**Files:**
- Create: `ruby/lib/keycloak_sdk/admin/bearer_auth.rb` · `admin/call.rb` · `admin/admin_client.rb`
- Create: `ruby/lib/keycloak_sdk/admin/users.rb` · `admin/clients.rb` · `admin/realms.rb` · `admin/roles.rb` · `admin/groups.rb`
- Modify: `ruby/lib/keycloak_sdk.rb`
- Test: `ruby/spec/unit/admin_spec.rb`

**Interfaces:**
- Consumes: `Config`, `TokenProvider`(`#access_token`), `Http`, `AdminError`(`.from_status`), `NotFoundError`/`ConflictError`/`ForbiddenError`, `TransportError`.
- Produces:
  - `KeycloakSdk::Admin::AdminClient.new(config:, token_provider:)`; `#users #clients #realms #roles #groups` → 리소스, `#raw → Faraday::Connection`(탈출구).
  - 각 리소스: `#create(rep) → id(String, Location 헤더에서)` · `#get(id) → Hash` · `#list(**params) → Array` · `#update(id, rep) → nil` · `#delete(id) → nil`. Realms는 `#create(rep) → realm_name` · `#get(realm)` · `#list → Array` · `#update(realm, rep)` · `#delete(realm)`.
  - `KeycloakSdk::Admin::BearerAuth`(Faraday 미들웨어, 매 요청 `Authorization: Bearer <token_provider.access_token>`).

- [ ] **Step 1: `spec/unit/admin_spec.rb` (failing — 오류 경계·Location id)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::Admin::AdminClient do
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: "svc", client_secret: "sekret")
  end
  let(:token_provider) { instance_double(KeycloakSdk::ClientCredentialsTokenProvider, access_token: "AT") }
  let(:users_url) { "https://kc.example.com/admin/realms/demo/users" }

  subject(:admin) { described_class.new(config: config, token_provider: token_provider) }

  it "sends a bearer token from the provider and returns the created id from Location" do
    stub = stub_request(:post, users_url)
           .with(headers: { "Authorization" => "Bearer AT" })
           .to_return(status: 201, headers: { "Location" => "#{users_url}/abc-123" })
    id = admin.users.create({ username: "alice" })
    expect(id).to eq("abc-123")
    expect(stub).to have_been_requested.once
  end

  it "maps 404 to NotFoundError" do
    stub_request(:get, "#{users_url}/missing").to_return(status: 404, body: "")
    expect { admin.users.get("missing") }.to raise_error(KeycloakSdk::NotFoundError)
  end

  it "maps 409 to ConflictError" do
    stub_request(:post, users_url).to_return(status: 409, body: { errorMessage: "exists" }.to_json,
                                             headers: { "Content-Type" => "application/json" })
    expect { admin.users.create({ username: "dup" }) }.to raise_error(KeycloakSdk::ConflictError)
  end

  it "maps 403 to ForbiddenError (e.g. POST /admin/realms by realm SA)" do
    stub_request(:post, "https://kc.example.com/admin/realms").to_return(status: 403, body: "")
    expect { admin.realms.create({ realm: "new" }) }.to raise_error(KeycloakSdk::ForbiddenError)
  end

  it "maps a timeout to TransportError" do
    stub_request(:get, "#{users_url}/x").to_raise(Faraday::TimeoutError.new("t"))
    expect { admin.users.get("x") }.to raise_error(KeycloakSdk::TransportError)
  end

  it "exposes the raw Faraday connection as an escape hatch" do
    expect(admin.raw).to be_a(Faraday::Connection)
  end
end
```

- [ ] **Step 2: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/admin_spec.rb`
Expected: FAIL (`uninitialized constant KeycloakSdk::Admin`).

- [ ] **Step 3: `lib/keycloak_sdk/admin/bearer_auth.rb`**

```ruby
# frozen_string_literal: true

require "faraday"

module KeycloakSdk
  module Admin
    # 매 요청마다 TokenProvider에서 bearer 토큰을 소싱해 Authorization 헤더를 설정한다.
    class BearerAuth < Faraday::Middleware
      def initialize(app, token_provider)
        super(app)
        @token_provider = token_provider
      end

      def on_request(env)
        env.request_headers["Authorization"] = "Bearer #{@token_provider.access_token}"
      end
    end
  end
end
```

- [ ] **Step 4: `lib/keycloak_sdk/admin/call.rb` (오류 경계 + Location)**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # 리소스 공용: 요청 실행 + 오류 경계 변환 + Location 헤더 id 추출.
    module Call
      private

      def request
        resp = yield
        return resp if resp.success?

        raise AdminError.from_status(resp.status, "admin request failed: HTTP #{resp.status}")
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        raise TransportError, "admin transport error: #{e.message}"
      end

      def id_from_location(resp)
        loc = resp.headers["location"] || resp.headers["Location"]
        loc&.split("/")&.last
      end
    end
  end
end
```

- [ ] **Step 5: 5개 리소스 파일 작성**

`lib/keycloak_sdk/admin/users.rb`:
```ruby
# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Users
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        id_from_location(request { @conn.post("#{@realm}/users", representation) })
      end

      def get(id)
        request { @conn.get("#{@realm}/users/#{id}") }.body
      end

      def list(**params)
        request { @conn.get("#{@realm}/users", params) }.body
      end

      def update(id, representation)
        request { @conn.put("#{@realm}/users/#{id}", representation) }
        nil
      end

      def delete(id)
        request { @conn.delete("#{@realm}/users/#{id}") }
        nil
      end
    end
  end
end
```

`lib/keycloak_sdk/admin/clients.rb`:
```ruby
# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Clients
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        id_from_location(request { @conn.post("#{@realm}/clients", representation) })
      end

      def get(id)
        request { @conn.get("#{@realm}/clients/#{id}") }.body
      end

      # client_id로 조회: 목록 + 필터(admin은 내부 uuid 키).
      def list(**params)
        request { @conn.get("#{@realm}/clients", params) }.body
      end

      def update(id, representation)
        request { @conn.put("#{@realm}/clients/#{id}", representation) }
        nil
      end

      def delete(id)
        request { @conn.delete("#{@realm}/clients/#{id}") }
        nil
      end
    end
  end
end
```

`lib/keycloak_sdk/admin/roles.rb` (realm 롤 — name 키):
```ruby
# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Roles
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        id_from_location(request { @conn.post("#{@realm}/roles", representation) })
      end

      def get(name)
        request { @conn.get("#{@realm}/roles/#{name}") }.body
      end

      def list(**params)
        request { @conn.get("#{@realm}/roles", params) }.body
      end

      def update(name, representation)
        request { @conn.put("#{@realm}/roles/#{name}", representation) }
        nil
      end

      def delete(name)
        request { @conn.delete("#{@realm}/roles/#{name}") }
        nil
      end
    end
  end
end
```

`lib/keycloak_sdk/admin/groups.rb`:
```ruby
# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Groups
      include Call

      def initialize(conn, realm)
        @conn = conn
        @realm = realm
      end

      def create(representation)
        id_from_location(request { @conn.post("#{@realm}/groups", representation) })
      end

      def get(id)
        request { @conn.get("#{@realm}/groups/#{id}") }.body
      end

      def list(**params)
        request { @conn.get("#{@realm}/groups", params) }.body
      end

      def update(id, representation)
        request { @conn.put("#{@realm}/groups/#{id}", representation) }
        nil
      end

      def delete(id)
        request { @conn.delete("#{@realm}/groups/#{id}") }
        nil
      end
    end
  end
end
```

`lib/keycloak_sdk/admin/realms.rb` (top-level — name 키):
```ruby
# frozen_string_literal: true

module KeycloakSdk
  module Admin
    class Realms
      include Call

      def initialize(conn)
        @conn = conn
      end

      # POST /admin/realms — master realm 전용(realm SA는 403). 반환: realm 이름.
      def create(representation)
        request { @conn.post("", representation) }
        representation[:realm] || representation["realm"]
      end

      def get(realm)
        request { @conn.get(realm) }.body
      end

      def list
        request { @conn.get("") }.body
      end

      def update(realm, representation)
        request { @conn.put(realm, representation) }
        nil
      end

      def delete(realm)
        request { @conn.delete(realm) }
        nil
      end
    end
  end
end
```

- [ ] **Step 6: `lib/keycloak_sdk/admin/admin_client.rb`**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  module Admin
    # Admin REST 파사드. gem 없이 Faraday로 직접 래핑하고, bearer는 주입된 TokenProvider에서 소싱한다.
    # representation은 plain hash로 통과한다(문서화된 은닉성 예외).
    class AdminClient
      def initialize(config:, token_provider:)
        @config = config
        @conn = build_conn(config, token_provider)
      end

      def users
        Users.new(@conn, @config.realm)
      end

      def clients
        Clients.new(@conn, @config.realm)
      end

      def realms
        Realms.new(@conn)
      end

      def roles
        Roles.new(@conn, @config.realm)
      end

      def groups
        Groups.new(@conn, @config.realm)
      end

      # 탈출구: 내부 Faraday 커넥션(base = {server_url}/admin/realms/, bearer 자동).
      def raw
        @conn
      end

      private

      def build_conn(config, token_provider)
        Http.build(config, base_url: "#{config.server_url}/admin/realms/") do |f|
          f.request :json
          f.response :json, content_type: /\bjson$/
          f.use BearerAuth, token_provider
        end
      end
    end
  end
end
```

- [ ] **Step 7: 배럴 require 추가**

`lib/keycloak_sdk.rb`의 auth_client require 아래:
```ruby
require_relative "keycloak_sdk/admin/call"
require_relative "keycloak_sdk/admin/bearer_auth"
require_relative "keycloak_sdk/admin/users"
require_relative "keycloak_sdk/admin/clients"
require_relative "keycloak_sdk/admin/realms"
require_relative "keycloak_sdk/admin/roles"
require_relative "keycloak_sdk/admin/groups"
require_relative "keycloak_sdk/admin/admin_client"
```

- [ ] **Step 8: Run — 통과 + 린트 + Commit**

Run: `cd ruby && bundle exec rspec spec/unit/admin_spec.rb && bundle exec rubocop lib/keycloak_sdk/admin/`
Expected: PASS · rubocop 무경고.

```bash
git add ruby/lib/keycloak_sdk/admin/ ruby/lib/keycloak_sdk.rb ruby/spec/unit/admin_spec.rb
git commit -m "feat(ruby): AdminClient — Faraday raw-REST 5리소스(users/clients/realms/roles/groups)+bearer 미들웨어+오류경계(Location id·404/409/403)+raw()"
```

---

### Task 10: client.rb (KeycloakClient 통합 진입점)

> **커버리지 경계**: `client.rb`는 SimpleCov omit. 이 태스크 끝에서 **전체 단위 스위트 + 커버리지 게이트**를 확인한다(로직 모듈 라인 ≥90/브랜치 ≥85).

**Files:**
- Create: `ruby/lib/keycloak_sdk/client.rb`
- Modify: `ruby/lib/keycloak_sdk.rb`
- Test: `ruby/spec/unit/client_spec.rb`

**Interfaces:**
- Consumes: 전 계층.
- Produces: `KeycloakSdk::KeycloakClient.new(config) → client`; `#auth → AuthClient`(즉시) · `#admin → Admin::AdminClient`(지연·메모이즈, 전용 캐싱 `ClientCredentialsTokenProvider` 주입) · `#close`.

- [ ] **Step 1: `spec/unit/client_spec.rb` (failing)**

```ruby
# frozen_string_literal: true

require "spec_helper"

RSpec.describe KeycloakSdk::KeycloakClient do
  let(:config) do
    KeycloakSdk::Config.new(server_url: "https://kc.example.com", realm: "demo",
                            client_id: "app", client_secret: "sekret")
  end

  subject(:client) { described_class.new(config) }

  it "builds the auth facade eagerly" do
    expect(client.auth).to be_a(KeycloakSdk::AuthClient)
  end

  it "builds the admin facade lazily and memoizes it" do
    expect(client.admin).to be_a(KeycloakSdk::Admin::AdminClient)
    expect(client.admin).to equal(client.admin)
  end

  it "responds to close" do
    expect { client.close }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run — 실패 확인**

Run: `cd ruby && bundle exec rspec spec/unit/client_spec.rb`
Expected: FAIL (`uninitialized constant`).

- [ ] **Step 3: `lib/keycloak_sdk/client.rb` 구현**

```ruby
# frozen_string_literal: true

module KeycloakSdk
  # 통합 진입점. auth는 즉시 조립, admin은 지연 조립(전용 캐싱 TokenProvider 주입 — §4).
  class KeycloakClient
    attr_reader :auth

    def initialize(config)
      @config = config
      endpoints = OidcEndpoints.from_config(config)
      @form_http = Http.build(config) { |f| f.request :url_encoded; f.response :json, content_type: /\bjson$/ }
      @jwks_http = Http.build(config) { |f| f.response :json, content_type: /\bjson$/ }
      jwks_store = JwksStore.new(jwks_url: endpoints.jwks, http: @jwks_http)
      jwt_validator = JwtValidator.from_config(config: config, jwks_store: jwks_store)
      @auth = AuthClient.new(config: config, http: @form_http, jwt_validator: jwt_validator)
      @admin = nil
      @admin_mutex = Mutex.new
    end

    def admin
      @admin_mutex.synchronize do
        @admin ||= Admin::AdminClient.new(
          config: @config,
          token_provider: ClientCredentialsTokenProvider.new(config: @config, http: @form_http)
        )
      end
    end

    def close
      [@form_http, @jwks_http].each { |h| h.close if h.respond_to?(:close) }
      nil
    end
  end
end
```

- [ ] **Step 4: 배럴 require 추가**

`lib/keycloak_sdk.rb`의 admin requires 아래:
```ruby
require_relative "keycloak_sdk/client"
```

- [ ] **Step 5: 전체 단위 스위트 + 커버리지 게이트 확인**

Run: `cd ruby && bundle exec rspec` (전체 단위, `:integration` 제외 자동)
Expected: 모든 예제 PASS · **SimpleCov 종료 시 "Line coverage ≥ 90% / Branch coverage ≥ 85%"**(경계 파일 omit 후 로직 모듈 기준). 미달 시 미커버 브랜치를 단위로 보강한다(구현 코드는 그대로).

Run: `cd ruby && bundle exec rubocop`
Expected: 무경고(전체).

- [ ] **Step 6: Commit**

```bash
git add ruby/lib/keycloak_sdk/client.rb ruby/lib/keycloak_sdk.rb ruby/spec/unit/client_spec.rb
git commit -m "feat(ruby): KeycloakClient 통합 진입점(auth 즉시·admin 지연+전용 캐싱 provider·close) + 전체 단위 GREEN·커버리지 게이트 통과"
```

---

### Task 11: 통합 테스트 (docker-CLI 셸아웃, 실제 Keycloak 26.6)

**Files:**
- Create: `ruby/spec/support/keycloak_container.rb` · `ruby/spec/integration/full_flow_spec.rb`
- Create: `ruby/spec/fixtures/it-realm-realm.json` (go/testdata에서 복사)

**Interfaces:**
- Consumes: `KeycloakClient`, `Admin::AdminClient`, `Config`, 전 계층. `KeycloakContainer.start/stop/base_url`.

- [ ] **Step 1: realm JSON 복사**

Run:
```bash
cp /d/Source/KeyCloakSDK/go/testdata/it-realm-realm.json /d/Source/KeyCloakSDK/ruby/spec/fixtures/it-realm-realm.json
```
> 이 realm은 `it-realm` + confidential client(service account·client-credentials, `it-client`/시크릿) + 서비스계정 realm-management 롤을 포함한다(Java/Python/Node/Go/Rust 재사용). 실제 필드는 복사본으로 확인한다.

- [ ] **Step 2: `spec/support/keycloak_container.rb` (docker CLI 셸아웃 헬퍼)**

```ruby
# frozen_string_literal: true

require "open3"
require "net/http"
require "uri"

# Docker CLI 셸아웃으로 실제 Keycloak 26.6을 기동한다.
# (testcontainers-ruby는 stale 0.2.0 + docker-api가 Windows npipe 미지원 → PHP 동형 셸아웃.)
class KeycloakContainer
  IMAGE = "quay.io/keycloak/keycloak:26.6"
  attr_reader :base_url

  def initialize(fixtures_dir:)
    @fixtures_dir = fixtures_dir
    @name = "kc-ruby-it-#{Process.pid}-#{rand(10_000)}"
  end

  def start
    run!("docker", "run", "-d", "--name", @name, "-p", "8080",
         "-e", "KEYCLOAK_ADMIN=admin", "-e", "KEYCLOAK_ADMIN_PASSWORD=admin",
         "-v", "#{docker_path(@fixtures_dir)}:/opt/keycloak/data/import:ro",
         IMAGE, "start-dev", "--import-realm")
    @base_url = "http://localhost:#{discover_port}"
    wait_ready!
    @base_url
  end

  def stop
    system("docker", "rm", "-f", @name, out: File::NULL, err: File::NULL)
  end

  private

  def discover_port
    out, _e, _s = Open3.capture3("docker", "port", @name, "8080/tcp")
    out[/:(\d+)\s*\z/, 1] or raise "could not discover mapped port: #{out.inspect}"
  end

  def wait_ready!(timeout: 120)
    deadline = Time.now + timeout
    uri = URI("#{@base_url}/realms/master")
    loop do
      raise "Keycloak did not become ready within #{timeout}s" if Time.now > deadline

      begin
        return if Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
      rescue StandardError
        # not up yet
      end
      sleep 2
    end
  end

  def run!(*cmd)
    out, err, status = Open3.capture3(*cmd)
    raise "command failed (#{status.exitstatus}): #{cmd.join(' ')}\n#{err}#{out}" unless status.success?

    out
  end

  # Git Bash(Windows) 경로를 Docker Desktop가 수용하는 형태로 변환.
  # /d/... 형태는 그대로 두고, C:\ 형태만 //c/ 로 변환(대개 절대경로가 이미 unix 형태).
  def docker_path(path)
    path.tr("\\", "/").sub(%r{\A([A-Za-z]):/}) { "//#{Regexp.last_match(1).downcase}/" }
  end
end
```

- [ ] **Step 3: `spec/integration/full_flow_spec.rb` (실제 KC E2E — tag :integration)**

```ruby
# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "json"
require_relative "../support/keycloak_container"

RSpec.describe "Keycloak full flow", :integration do
  before(:all) do
    WebMock.allow_net_connect! # 통합에서는 실네트워크 허용
    @container = KeycloakContainer.new(fixtures_dir: File.expand_path("../fixtures", __dir__))
    @base = @container.start
  end

  after(:all) do
    @container&.stop
    WebMock.disable_net_connect!(allow_localhost: false)
  end

  let(:config) do
    KeycloakSdk::Config.new(server_url: @base, realm: "it-realm",
                            client_id: "it-client", client_secret: "it-secret")
  end
  let(:client) { KeycloakSdk::KeycloakClient.new(config) }

  it "runs client-credentials → validate → introspect → CRUD (users/clients/roles/groups) → realm CRUD → raw → NotFound" do
    # 1) client-credentials 토큰 + 강화 검증(다중 aud 수용)
    token = client.auth.client_credentials_token
    expect(token.access_token).to be_a(String)
    validated = client.auth.validate(token.access_token)
    expect(validated.issuer).to eq("#{@base}/realms/it-realm")

    # 2) introspection
    intro = client.auth.introspect(token.access_token)
    expect(intro.active?).to be(true)

    # 3) user CRUD
    admin = client.admin
    uid = admin.users.create({ username: "alice", enabled: true, email: "alice@example.com" })
    expect(uid).to be_a(String)
    expect(admin.users.get(uid)["username"]).to eq("alice")
    admin.users.update(uid, { firstName: "Alice" })
    admin.users.delete(uid)
    expect { admin.users.get(uid) }.to raise_error(KeycloakSdk::NotFoundError)

    # 4) client CRUD
    cid = admin.clients.create({ clientId: "created-by-sdk", enabled: true })
    expect(admin.clients.get(cid)["clientId"]).to eq("created-by-sdk")
    admin.clients.delete(cid)

    # 5) role CRUD(name 키)
    admin.roles.create({ name: "sdk-role" })
    expect(admin.roles.get("sdk-role")["name"]).to eq("sdk-role")
    admin.roles.delete("sdk-role")

    # 6) group CRUD
    gid = admin.groups.create({ name: "sdk-group" })
    expect(admin.groups.get(gid)["name"]).to eq("sdk-group")
    admin.groups.delete(gid)

    # 7) realm CRUD via master-admin(realm SA는 403 — master bootstrap admin 토큰 사용)
    master_token = fetch_master_token
    master_tp = Struct.new(:access_token).new(master_token)
    master_admin = KeycloakSdk::Admin::AdminClient.new(config: config, token_provider: master_tp)
    master_admin.realms.create({ realm: "sdk-created-realm", enabled: true })
    expect(master_admin.realms.get("sdk-created-realm")["realm"]).to eq("sdk-created-realm")
    master_admin.realms.delete("sdk-created-realm")

    # 8) raw() 탈출구
    raw_resp = admin.raw.get("it-realm/users", { max: 1 })
    expect(raw_resp.status).to eq(200)
  ensure
    client&.close
  end

  private

  # master realm admin-cli 비밀번호 그랜트로 부트스트랩 토큰 획득(realm 생성 권한).
  def fetch_master_token
    uri = URI("#{@base}/realms/master/protocol/openid-connect/token")
    res = Net::HTTP.post_form(uri, grant_type: "password", client_id: "admin-cli",
                                   username: "admin", password: "admin")
    JSON.parse(res.body).fetch("access_token")
  end
end
```

- [ ] **Step 4: 통합 실행(Docker 필요) + Commit**

Run:
```bash
export PATH="/c/Users/dirtc/tools/ruby/bin:$PATH"
cd ruby && RUN_INTEGRATION=1 bundle exec rspec spec/integration/full_flow_spec.rb --tag integration
```
Expected: 1 example, 0 failures(실제 KC 26.6 컨테이너 기동 → 전 흐름 GREEN). 최초 실행은 이미지 pull로 수 분 소요.

> ⚠️ realm JSON의 client/secret 필드가 복사본과 다르면 config의 `client_id`/`client_secret`을 실제 값에 맞춘다(Java/Go testdata와 동일해야 함). Windows에서 볼륨 마운트 실패 시 `docker_path` 변환 또는 Docker Desktop 파일 공유 설정을 확인한다.

```bash
git add ruby/spec/support/keycloak_container.rb ruby/spec/integration/full_flow_spec.rb ruby/spec/fixtures/it-realm-realm.json
git commit -m "test(ruby): 통합 E2E(docker-CLI 셸아웃·실제 KC 26.6) — client-credentials→validate→introspect→user/client/role/group CRUD→realm CRUD(master-admin)→raw→NotFound"
```

---

### Task 12: CI · 릴리스 · 예제 · 문서

**Files:**
- Create: `.github/workflows/ruby-ci.yml` · `.github/workflows/ruby-release.yml`
- Create: `ruby/examples/quickstart.rb` · `ruby/README.md`
- Modify: `docs/guides/getting-started.md` · `README.md` · `CLAUDE.md` · `docs/roadmap/language-support.md`
- Create: `docs/governance/verification-log-ruby.md`

- [ ] **Step 1: `.github/workflows/ruby-ci.yml`**

```yaml
name: ruby-ci
on:
  push:
    paths: ["ruby/**", ".github/workflows/ruby-ci.yml"]
  pull_request:
    paths: ["ruby/**", ".github/workflows/ruby-ci.yml"]
jobs:
  build-test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        ruby: ["3.2", "3.3", "3.4"]
    defaults:
      run:
        working-directory: ruby
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
          working-directory: ruby
      - run: bundle exec rubocop
      - run: bundle exec rspec           # 단위(integration 자동 제외)
      - run: bundle exec bundler-audit check --update
  integration:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ruby
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
          bundler-cache: true
          working-directory: ruby
      - run: RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration
```

- [ ] **Step 2: `.github/workflows/ruby-release.yml` (human-gated · Trusted Publishing)**

```yaml
name: ruby-release
on:
  push:
    tags: ["ruby-v*"]
jobs:
  release:
    runs-on: ubuntu-latest
    environment: release
    permissions:
      contents: read
      id-token: write          # RubyGems Trusted Publishing(OIDC) — 저장 시크릿 없음
    defaults:
      run:
        working-directory: ruby
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
          bundler-cache: true
          working-directory: ruby
      - run: bundle exec rubocop
      - run: bundle exec rspec
      - run: bundle exec bundler-audit check --update
      - uses: rubygems/release-gem@v1
        with:
          working-directory: ruby
```
> ⚠️ **첫 게시 선행(1회)**: gem이 rubygems.org에 존재하기 전에는 Trusted Publisher를 붙일 수 없다 — 최초 1회는 API 키로 `gem push`하거나 `gem exec rubygems_configure_trusted_publisher`(또는 rubygems.org UI에서 gem 생성 후 Trusted Publisher: owner `xzawed`·repo `KeyCloakSDK`·workflow `ruby-release.yml`·environment `release` 등록). 이후 `ruby-v*` 태그 push로 무시크릿 릴리스.

- [ ] **Step 3: `ruby/examples/quickstart.rb`**

```ruby
# frozen_string_literal: true

require "keycloak_sdk"

config = KeycloakSdk::Config.new(
  server_url: ENV.fetch("KC_URL", "http://localhost:8080"),
  realm: ENV.fetch("KC_REALM", "it-realm"),
  client_id: ENV.fetch("KC_CLIENT_ID", "it-client"),
  client_secret: ENV.fetch("KC_CLIENT_SECRET", "it-secret")
)

client = KeycloakSdk::KeycloakClient.new(config)

token = client.auth.client_credentials_token
puts "access token acquired (expires_in=#{token.expires_in})"

validated = client.auth.validate(token.access_token)
puts "validated: sub=#{validated.subject} iss=#{validated.issuer}"

puts "introspection active=#{client.auth.introspect(token.access_token).active?}"

user_id = client.admin.users.create({ username: "quickstart-user", enabled: true })
puts "created user #{user_id}"
client.admin.users.delete(user_id)
puts "deleted user"

client.close
```

- [ ] **Step 4: 빌드/린트/설치 최종 검증**

Run:
```bash
export PATH="/c/Users/dirtc/tools/ruby/bin:$PATH"
cd ruby && bundle exec rubocop && bundle exec rspec && gem build keycloak-sdk.gemspec && ruby -Ilib examples/quickstart.rb 2>/dev/null || echo "(quickstart는 KC 필요 — 빌드/require만 확인)"
```
Expected: rubocop 무경고 · 전체 단위 GREEN + 커버리지 게이트 통과 · `keycloak-sdk-0.1.0.gem` 생성(gemspec `spec.files` 유효).

- [ ] **Step 5: `ruby/README.md` 작성**

내용(요지): 설치(`gem install keycloak-sdk`/Gemfile), 빠른 시작(위 quickstart 요약), 설정(`KeycloakSdk::Config` 필드·기본값), auth(client-credentials·authcode+PKCE·refresh·introspect·logout·validate)·admin(5리소스·raw) 사용 예, 보안(자체강화 JWT·마스킹·SSRF·TLS), 예외 계층, Ruby `>= 3.2`, 라이선스 Apache-2.0, "8개 언어 폴리글랏 SDK 중 Ruby 구현" 문구.

- [ ] **Step 6: 프로젝트 문서 갱신(전역 규칙)**

- `docs/guides/getting-started.md`: Ruby 섹션 추가(설치·설정·빠른 시작·툴체인 명령).
- `README.md`(루트): 언어 목록에 **Ruby(8번째)** 추가, 배지/표 갱신.
- `CLAUDE.md`: (a) 프로젝트 개요에 8번째 언어 Ruby 한 줄, (b) 현재 상태에 "Ruby SDK 완료 — 병합됨(PR #19)" 블록, (c) 아키텍처에 `ruby/` 트리 + 결합 규칙, (d) 게차 섹션에 Ruby 게차(ruby-jwt 기본값·RS256핀 pre-gate 불요·KeyFinder 재생성·rack-oauth2 PKCE passthrough·admin gem 부재→Faraday·docker-CLI·Ruby 4.0/floor 3.2·모듈명), (e) 테스트 수(단위 N + 통합 1 = 총 M), (f) Ruby 툴체인(빌드 명령) 서브섹션, (g) 확정 의존성 표에 Ruby 행.
- `docs/roadmap/language-support.md`: 현황 매트릭스의 Ruby 행을 `계획`→`✅`로, rank 6 Ruby 행 "구현 완료" 확정 사실 갱신, 완료 문단 "8개 언어".
- `docs/governance/verification-log-ruby.md`: 신규 — 태스크별 게이트(rubocop·rspec·SimpleCov·bundler-audit) 통과 이력 + 딥리서치 확정 라이브러리 + 게차.

- [ ] **Step 7: 최종 검증 + Commit**

Run: `cd ruby && bundle exec rubocop && bundle exec rspec`
Expected: 전체 GREEN.

```bash
git add ruby/ .github/workflows/ruby-ci.yml .github/workflows/ruby-release.yml docs/ README.md CLAUDE.md
git commit -m "ci+docs(ruby): ruby-ci(매트릭스 3.2/3.3/3.4+Docker 통합) · ruby-release(Trusted Publishing·human-gated) · quickstart · README · 문서 전체 갱신"
```

---

## Self-Review (작성자 체크)

**1. Spec coverage** — 설계 스펙 §별 태스크 매핑:
- §2 라이브러리(jwt/rack-oauth2/faraday) → Task 1(gemspec deps)·7(jwt)·8(rack-oauth2)·4/9(faraday). ✅
- §3 아키텍처 전 계층 → config(T3)·errors/masking(T2)·tokens/oidc/http(T4)·token_provider(T5)·jwks(T6)·jwt(T7)·auth(T8)·admin(T9)·client(T10). ✅
- §4 오류 경계(Error 계층·admin 404/409/403·auth oauth_error·jwt) → T2(계층)·T9(admin 매핑)·T5/T8(auth)·T7(jwt). ✅
- §5 보안 불변식(RS256핀·none·iss·aud·exp/nbf·스큐·DoS-safe JWKS·마스킹·SSRF·TLS·타임아웃·bundler-audit) → T7(JWT 강화 전부)·T6(JWKS)·T3/T4(마스킹)·T4/T9(SSRF: follow_redirects 미장착)·T4(타임아웃)·T12(bundler-audit). ✅
- §6 툴체인/테스트/CI(RSpec+WebMock+SimpleCov 90/85+RuboCop·docker-CLI 통합·Trusted Publishing) → T1(spec_helper/rubocop)·T10(게이트)·T11(통합)·T12(CI/릴리스). ✅
- §7 테스트 패리티(단위 전부·통합 전 흐름) → 각 태스크 단위 스펙 + T11 E2E. ✅
- §8 게차 → 코드 주석 + T12 문서(CLAUDE.md 게차 섹션). ✅
- §9 DoD → T10(단위+게이트)·T11(통합)·T12(CI/문서). ✅

**2. Placeholder scan** — "TBD/TODO/적절히 처리" 없음. 모든 코드 스텝에 완전한 코드. 문서 갱신(T12 Step 6)만 산문 지시(코드 아님 — 허용). ✅

**3. Type consistency** — 교차 태스크 시그니처 확인:
- `TokenProvider#access_token`(T5 정의) = admin BearerAuth(T9)·client(T10)·AuthClient(T8)에서 동일 호출. ✅
- `TokenSet.from_response(body, received_at:)`(T4) = token_provider(T5)에서 동일 호출. ✅
- `OidcEndpoints.from_config(config)`(T4) = token_provider(T5)·jwt_validator(T7)·auth(T8)·client(T10) 동일. ✅
- `JwksStore#key_set(force:)`(T6) = jwt_validator 로더(T7) 동일. ✅
- `JwtValidator.from_config(config:, jwks_store:)`(T7) = client(T10) 동일. ✅
- `AdminError.from_status(status, message)`(T2) = admin Call(T9) 동일. ✅
- `Http.build(config, base_url:)`(T4) = T5/T6/T9/T10 동일 시그니처. ✅
- `Admin::AdminClient.new(config:, token_provider:)`(T9) = client(T10)·통합(T11) 동일. ✅

이슈 없음 — 계획 확정.

