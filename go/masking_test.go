package keycloak

import "testing"

func TestMask(t *testing.T) {
	if got := mask("supersecret"); got != "***" {
		t.Fatalf("mask must be fully opaque, got %q", got)
	}
	if got := mask(""); got != "***" {
		t.Fatalf("empty also masked, got %q", got)
	}
}
