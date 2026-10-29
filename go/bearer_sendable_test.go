package keycloak

import "testing"

// The SDK's bearer grammar (sendableBearer, tokenprovider.go) is narrower than the transport's header rule, never wider:
// a token it accepts is one net/http carries, so no admin call can fail inside the transport with the opaque error
// admin_bearer_header_test.go measured. Every byte is compared with the transport once — one transport, one server: the
// oracle opens one connection, not one per byte (admin_bearer_header_test.go). The grammar's own rows are
// bearer_grammar_test.go's.
func TestSendableBearerIsNoWiderThanTheTransport(t *testing.T) {
	refused := bearerRefusedByTransport(t)
	accepted := 0
	for b := 0; b < 256; b++ {
		_, ok := sendableBearer(bearerRow(byte(b)))
		if ok {
			accepted++
		}
		if ok && refused[b] {
			t.Errorf("byte %#02x: sendableBearer accepts it, but the transport refuses it", b)
		}
	}
	// The b64token alphabet: 26 + 26 + 10 letters and digits, and "-", ".", "_", "~", "+", "/". "=" is padding, so it is
	// refused in the middle of a token.
	if accepted != 68 {
		t.Errorf("sendableBearer accepted %d bytes in the middle of a token, want the 68 of the b64token alphabet", accepted)
	}
}
