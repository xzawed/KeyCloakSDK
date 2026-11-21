//go:build integration

package fixture

import "testing"

// TestE2EDrive runs only under -tags=integration — the unit run (no tags) never compiles it, so LogoutURL stays
// unreached there.
func TestE2EDrive(t *testing.T) {
	a := &AuthClient{realm: "r"}
	if a.LogoutURL() != "https://idp.example/realms/r/logout" {
		t.Fatal("logout url")
	}
}
