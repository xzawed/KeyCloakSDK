# frozen_string_literal: true

require "spec_helper"

# The unit run leaves this out (spec_helper's filter_run_excluding(:integration)) — it calls logout_url, which the unit drive
# does not.
RSpec.describe "fixture integration drive", :integration do
  it "calls what the unit drive does not" do
    auth = Kc::AuthClient.new(Kc::Config.new(realm: "r", base: "http://kc"))
    expect(auth.logout_url).to eq("http://kc/logout")
  end
end
