# frozen_string_literal: true

require "spec_helper"

RSpec.describe "KeycloakSdk::VERSION" do
  it "exposes a semver VERSION" do
    expect(KeycloakSdk::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
