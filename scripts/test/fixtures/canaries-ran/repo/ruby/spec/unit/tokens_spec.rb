RSpec.describe "tokens" do
  it "rejects a mismatched nonce" do
  end

  [1, nil].each do |bad|
    it "rejects a non-string access_token (#{bad.inspect})" do
    end
  end
end
