# frozen_string_literal: true

require "spec_helper"

# Drives part of the boundary — never an empty code, never a missing key, never a falsy fallback, no items through apply's
# block, never nil claims, never describe, never logout_url, never a nil parse. token takes both arms.
RSpec.describe "fixture unit drive" do
  it "drives part of the boundary" do
    auth = Kc::AuthClient.new(Kc::Config.new(realm: "r", base: "http://kc"))
    expect(auth.realm).to eq("r")
    expect(auth.token("svc")).to eq("r:svc")
    expect(auth.token(nil)).to eq("r:default")
    expect(auth.exchange("c")).to eq("token:c")
    expect(auth.pick({ "a" => 1 }, "a")).to eq(1)
    expect(auth.fallback("x")).to eq("x")
    expect(auth.apply([])).to eq([])
    expect(auth.realm_of({ realm: "r" })).to eq("r")
    expect(Kc::AuthClient.parse(" x ")).to eq("x")
  end
end
