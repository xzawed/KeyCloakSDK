package x

import "testing"

func TestBefore(t *testing.T) {}

func helper(t *testing.T) {
	assertMasked(t, "TokenSet", "x")
}
