# frozen_string_literal: true

# Fixture for scripts/test/test-integration-coverage.sh — the boundary is what SimpleCov skips here
# (scripts/coverage-boundary.mjs reads these lines, as it reads ruby/spec/spec_helper.rb in the real tree).
require "simplecov"

SimpleCov.start do
  skip %r{/spec/}
  skip "lib/kc/version.rb"
  # network boundary (fixture)
  skip "lib/kc/auth_client.rb"
  skip %r{lib/kc/admin/}
end

require_relative "../lib/kc"
