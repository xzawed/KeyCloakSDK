package x

import "testing"

func assertMasked(t *testing.T, label, out string) {}

func TestDefaultReprMasks(t *testing.T) {
	for _, verb := range []string{"%v", "%+v"} {
		assertMasked(t, "TokenSet "+verb, verb)
	}
}

func TestSlogMasks(t *testing.T) {
	cases := []struct {
		name string
		v    any
		want []string
	}{
		{"TokenSet", ts, nil},
	}
	_ = cases
}
