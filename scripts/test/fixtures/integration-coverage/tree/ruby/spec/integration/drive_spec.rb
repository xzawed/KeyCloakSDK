# frozen_string_literal: true

require "spec_helper"

RSpec.describe "fixture drive", :integration do
  it "drives part of the boundary" do
    cfg = Kc::Config.new(realm: "r", base: "http://kc")
    auth = Kc::AuthClient.new(cfg)
    expect(auth.token("svc")).to eq("r:svc")
    expect(Kc::AuthClient.parse(" x ")).to eq("x")
    expect(Kc::Admin::Client.new(auth).users).to eq(["r:admin"])
  end
end
