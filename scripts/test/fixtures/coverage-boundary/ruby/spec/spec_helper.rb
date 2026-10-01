# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  skip %r{/spec/}
  # skip "lib/sdk/config.rb"   ← 주석 속 항목은 세지 않는다
  skip "lib/sdk/auth_client.rb"
  skip %r{lib/sdk/admin/}
  minimum_coverage(line: 90, branch: 85)
end
