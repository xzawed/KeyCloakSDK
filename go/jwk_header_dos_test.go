package keycloak

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// GHSA-mgcc-cww5-fp2q: jwt.ParseSigned decodes a JWK embedded in the protected header and, up to
// go-jose 4.1.5, validated its RSA private parameters with crypto/rsa — cubic in the prime size,
// before any key lookup or signature check. Validate is the SDK's first contact with a bearer
// token from an unauthenticated caller, so one crafted header was a CPU denial of service.
// Measured through this Validate on go-jose 4.1.5: a 4,250-byte token with a 16,384-bit prime
// held it for 2.5 s (8,192 bits: 0.33 s); on 4.1.6 the same token is refused in about 1 ms.
//
// The SDK never uses a header key — keys come only from the JWKS by kid — so the token must be
// refused at parse time: no JWKS request, a TokenValidationError, and no echo of the header key.
func TestValidateRefusesEmbeddedJWKWithPrivateParamsBeforeAnyWork(t *testing.T) {
	f := newJWTFixture(t)
	v := f.validator(t, time.Second)
	enc := func(b *big.Int) string { return base64.RawURLEncoding.EncodeToString(b.Bytes()) }
	p := new(big.Int).Lsh(big.NewInt(1), 16383)
	p.SetBit(p, 0, 1)
	hdr, _ := json.Marshal(map[string]any{"alg": "RS256", "kid": "k1", "jwk": map[string]string{
		"kty": "RSA", "n": enc(new(big.Int).Lsh(big.NewInt(1), 2048)), "e": enc(big.NewInt(65537)),
		"d": enc(big.NewInt(3)), "p": enc(p), "q": enc(big.NewInt(3)),
	}})
	token := base64.RawURLEncoding.EncodeToString(hdr) + "." +
		base64.RawURLEncoding.EncodeToString([]byte(`{}`)) + "." +
		base64.RawURLEncoding.EncodeToString([]byte("not-a-real-signature"))

	start := time.Now()
	_, err := v.Validate(context.Background(), token)
	elapsed := time.Since(start)

	var tve *TokenValidationError
	if !errors.As(err, &tve) {
		t.Fatalf("want *TokenValidationError, got %T: %v", err, err)
	}
	// 4.1.5 took 2.5 s here and 4.1.6 about 1 ms; a one-second bound separates them on a slow runner.
	if elapsed > time.Second {
		t.Fatalf("Validate spent %v on a crafted header key — the embedded JWK was validated", elapsed)
	}
	if strings.Contains(err.Error(), `"d"`) || strings.Contains(err.Error(), `\"d\"`) {
		t.Fatalf("the error echoes the embedded key: %v", err)
	}
	if n := atomic.LoadInt32(f.fetches); n != 0 {
		t.Fatalf("a token refused at parse time must not reach the IdP, JWKS fetches = %d", n)
	}
}
