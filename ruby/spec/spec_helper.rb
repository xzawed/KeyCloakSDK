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
