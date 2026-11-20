# frozen_string_literal: true

require "spec_helper"

# Drives part of the boundary — never an empty code, never a missing key, no items through apply's block, never describe,
# never logout_url, never a nil parse.
RSpec.describe "fixture unit drive" do
  it "drives part of the boundary" do
    auth = Kc::AuthClient.new(Kc::Config.new(realm: "r", base: "http://kc"))
    expect(auth.realm).to eq("r")
    expect(auth.token("svc")).to eq("r:svc")
    expect(auth.exchange("c")).to eq("token:c")
    expect(auth.pick({ "a" => 1 }, "a")).to eq(1)
    expect(auth.apply([])).to eq([])
    expect(Kc::AuthClient.parse(" x ")).to eq("x")
  end
end
