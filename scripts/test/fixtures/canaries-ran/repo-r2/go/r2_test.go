package x

import "testing"

// TestCommentOnly mentions t.Run( only in comments — it opens no subtests.
func TestCommentOnly(t *testing.T) {
	// a later version might call t.Run(name, func(t *testing.T) {}) here
	_ = t
}

func TestReceiverSubtests(t *testing.T) {
	tt := t
	for _, c := range []string{"a", "b"} {
		tt.Run(c, func(t *testing.T) {
			t.Fatal("must run")
		})
	}
}
