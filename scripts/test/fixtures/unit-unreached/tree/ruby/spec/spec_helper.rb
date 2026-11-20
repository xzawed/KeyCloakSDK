# frozen_string_literal: true

# Fixture for scripts/test/test-unit-unreached.sh — the boundary is what SimpleCov skips here (scripts/coverage-boundary.mjs
# reads these lines, as it reads ruby/spec/spec_helper.rb in the real tree), and the unit run leaves :integration out as the
# real spec_helper does.
require "simplecov"

SimpleCov.start do
  skip %r{/spec/}
  # network boundary (fixture)
  skip "lib/kc/auth_client.rb"
end

require_relative "../lib/kc"

RSpec.configure do |config|
  config.filter_run_excluding(:integration) unless ENV["RUN_INTEGRATION"]
end
