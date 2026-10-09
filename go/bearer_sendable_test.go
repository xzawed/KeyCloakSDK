package keycloak

import "testing"

// The SDK transcribes the transport's header rule (bearerSendable, tokenprovider.go). This keeps the transcription equal
// to the transport for every byte, so a Go release that changes the rule fails here instead of reopening the opaque
// error — or a token the transport would carry being refused. One transport, one server: the oracle opens one
// connection, not one per byte (admin_bearer_header_test.go).
func TestBearerSendableMatchesTheTransport(t *testing.T) {
	refused := bearerRefusedByTransport(t)
	for b := 0; b < 256; b++ {
		if sendable := bearerSendable(bearerRow(byte(b))); sendable == refused[b] {
			t.Errorf("byte %#02x: bearerSendable = %v, but the transport refused it = %v", b, sendable, refused[b])
		}
	}
}
