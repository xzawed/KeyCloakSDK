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
  # 통합잡(spec/integration만 실행)은 로직 브랜치 대부분을 안 타므로 게이트를 적용하면 안 된다 —
  # RUN_INTEGRATION 환경변수로 unit 실행만 게이트를 강제한다(단위 게이트는 약화하지 않음).
  minimum_coverage(line: 90, branch: 85) unless ENV["RUN_INTEGRATION"]
end

require "webmock/rspec"
require "keycloak_sdk"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.filter_run_excluding(:integration) unless ENV["RUN_INTEGRATION"]
  WebMock.disable_net_connect!(allow_localhost: false)
end
