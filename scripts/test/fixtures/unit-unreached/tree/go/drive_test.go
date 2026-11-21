package fixture

import "testing"

// TestDrive is the unit drive: it never sends an empty code, always finds a "k" entry, passes both operands of
// Valid, calls the package-level hook, and never calls String or LogoutURL.
func TestDrive(t *testing.T) {
	a := &AuthClient{realm: "r"}
	if a.Realm() != "r" {
		t.Fatal("realm")
	}
	if tok, err := a.Exchange("c"); err != nil || tok != "tok-c" {
		t.Fatal("exchange")
	}
	if a.Pick([]string{"kx"}) != "kx" {
		t.Fatal("pick")
	}
	if !a.Valid("kx") {
		t.Fatal("valid")
	}
	if hook() != 1 {
		t.Fatal("hook")
	}
}
