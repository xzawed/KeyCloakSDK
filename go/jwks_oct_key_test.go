package keycloak

import (
	"context"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	jose "github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

// ⚠️ **JWKS 의 대칭(`oct`) 키는 검증 키가 아니다.** JWKS 는 공개 문서라 그 안의 대칭 키는 비밀이 아니다 — 그 키로 서명한 HS256
// 토큰을 받으면 키셋을 읽은 누구나 토큰을 위조한다. Keycloak 은 oct 를 JWKS 에 내지 않으므로 기본 경로가 아니라 HS 를 허용한
// 설정의 함정이다(등록부 jwks-oct-key-usable-with-hs · 아홉 언어 실측은 PR 본문). 수정 전 go 는 세 모양 모두 통과시켰다 — kid 가
// 없는 토큰은 kid 가 없는 키와 짝지어진다(`JSONWebKeySet.Key("")`).

func hsSign(t *testing.T, secret []byte, kid string, cl jwt.Claims) string {
	t.Helper()
	return hsSignWith(t, jose.HS256, secret, kid, cl)
}

func hsSignWith(t *testing.T, alg jose.SignatureAlgorithm, secret []byte, kid string, cl jwt.Claims) string {
	t.Helper()
	opts := (&jose.SignerOptions{}).WithType("JWT")
	if kid != "" {
		opts = opts.WithHeader("kid", kid)
	}
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: alg, Key: secret}, opts)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	s, err := jwt.Signed(sig).Claims(cl).Serialize()
	if err != nil {
		t.Fatalf("serialize: %v", err)
	}
	return s
}

func serveJWKS(t *testing.T, body string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(body)) }))
	t.Cleanup(srv.Close)
	return srv
}

func hsAllowed(uri string) *Validator {
	return newValidator(validatorOptions{jwksURI: uri, issuer: testISS, audience: "my-client",
		allowedAlgs: []jose.SignatureAlgorithm{jose.RS256, jose.HS256}, clockSkewSec: 30, minRefetch: time.Minute})
}

func TestValidateJWKSOctKeyIsNeverAVerificationKey(t *testing.T) {
	f := newJWTFixture(t)
	good, err := json.Marshal(jose.JSONWebKey{Key: &f.priv.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"})
	if err != nil {
		t.Fatal(err)
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	k := base64.RawURLEncoding.EncodeToString(secret)
	for name, tc := range map[string]struct{ oct, kid string }{
		"kid · alg": {`{"kty":"oct","kid":"hk","alg":"HS256","use":"sig","k":"` + k + `"}`, "hk"},
		"alg 없음":    {`{"kty":"oct","kid":"hk","k":"` + k + `"}`, "hk"},
		"kid 없음":    {`{"kty":"oct","alg":"HS256","use":"sig","k":"` + k + `"}`, ""},
	} {
		t.Run(name, func(t *testing.T) {
			// 전제 — go-jose 는 그 원소를 대칭 키로 읽는다(아니면 이 칸은 「못 읽는 키」를 잴 뿐이다).
			var jk jose.JSONWebKey
			if err := json.Unmarshal([]byte(tc.oct), &jk); err != nil {
				t.Fatalf("go-jose 가 oct 원소를 못 읽는다: %v", err)
			}
			if _, sym := jk.Key.([]byte); !sym {
				t.Fatalf("go-jose 가 oct 원소를 대칭 키로 읽지 않는다: %T", jk.Key)
			}
			v := hsAllowed(serveJWKS(t, `{"keys":[`+tc.oct+`,`+string(good)+`]}`).URL)
			forged := hsSign(t, secret, tc.kid, claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
			if vt, err := v.Validate(context.Background(), forged); err == nil {
				t.Fatalf("JWKS 의 oct 키로 서명한 위조 토큰이 통과했다(%s, sub=%s)", name, vt.Subject)
			} else if !errors.As(err, new(*TokenValidationError)) {
				t.Fatalf("위조 토큰의 거부는 TokenValidationError 여야 한다: %T %v", err, err)
			}
			// 대조 — 같은 키셋의 RSA 키로 서명한 토큰은 통과한다(oct 를 버리는 것이 키셋 전체를 버리지 않는다).
			if _, err := v.Validate(context.Background(),
				f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))); err != nil {
				t.Fatalf("같은 키셋의 RSA 토큰이 거부됐다: %v", err)
			}
		})
	}
}

// oct 만 있는 키셋은 쓸 수 있는 키가 없는 키셋이다 — 빈 키셋처럼 조회 실패로 닫고 설치하지 않는다.
func TestValidateJWKSWithOnlyAnOctKeyHasNoUsableKeys(t *testing.T) {
	f := newJWTFixture(t)
	v := hsAllowed(serveJWKS(t, `{"keys":[{"kty":"oct","kid":"k1","k":"c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlY3I"}]}`).URL)
	_, err := v.Validate(context.Background(),
		f.sign(t, f.priv, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute))))
	var te *TransportError
	if !errors.As(err, &te) || !strings.Contains(te.Msg, "no usable keys") {
		t.Fatalf("oct 만 있는 키셋은 TransportError(no usable keys)여야 한다: %v", err)
	}
}

// 고정 — HS 를 허용해도 RSA 공개키 바이트를 HMAC 비밀로 쓴 고전 RS→HS 혼동은 거부된다. 지금은 키를 찾기 전의 HS 거부가 먼저
// 받는다(TestValidateRefusesHSBeforeAnyKeyLookup) — 그 뒤의 go-jose 키 종류 · alg 결합은 이 경로에서 닿지 않는 겹친 방어다.
func TestValidateRSAPublicKeyBytesAsHMACSecretAreRejectedEvenWithHSAllowed(t *testing.T) {
	f := newJWTFixture(t)
	v := hsAllowed(f.jwksSrv.URL)
	der, err := x509.MarshalPKIXPublicKey(&f.priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	for name, secret := range map[string][]byte{
		"SPKI PEM": pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}),
		"SPKI DER": der,
		"n":        f.priv.PublicKey.N.Bytes(),
	} {
		forged := hsSign(t, secret, "k1", claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute)))
		if _, err := v.Validate(context.Background(), forged); err == nil {
			t.Fatalf("RSA 공개키(%s)를 HMAC 비밀로 쓴 HS256 토큰이 통과했다", name)
		}
	}
}

// HS 서명은 설정이 허용해도 키를 찾기 전에 거부한다(등록부 hs-refusal-rests-on-libraries) — 검증 키는 JWKS(공개 문서)에서만
// 오므로 HMAC 비밀이 될 수 있는 것은 공개된 값뿐이다. kid 는 JWKS 에 있는 RSA 키를 가리킨다. 계수기는 JWKS 요청이다 — 캐시가
// 비어 있어 키 조회는 곧 요청이다. 허용 목록 밖의 HS 는 지금의 길(go-jose 의 핀, `parse: `)에 남는다.
func TestValidateRefusesHSBeforeAnyKeyLookup(t *testing.T) {
	cl := claims(jwt.Audience{"my-client"}, testISS, time.Now().Add(5*time.Minute))
	for _, alg := range []jose.SignatureAlgorithm{jose.HS256, jose.HS384, jose.HS512} {
		t.Run(string(alg), func(t *testing.T) {
			f := newJWTFixture(t)
			secret := make([]byte, 64)
			if _, err := rand.Read(secret); err != nil {
				t.Fatal(err)
			}
			forged := hsSignWith(t, alg, secret, "k1", cl)
			v := newValidator(validatorOptions{jwksURI: f.jwksSrv.URL, issuer: testISS, audience: "my-client",
				allowedAlgs:  []jose.SignatureAlgorithm{jose.RS256, jose.HS256, jose.HS384, jose.HS512},
				clockSkewSec: 30, minRefetch: time.Minute})
			_, err := v.Validate(context.Background(), forged)
			var te *TokenValidationError
			if !errors.As(err, &te) {
				t.Fatalf("HS 토큰의 거부는 TokenValidationError 여야 한다: %T %v", err, err)
			}
			want := "algorithm not allowed: " + string(alg) + " (a JWKS holds public keys only)"
			if te.Msg != want || te.Cause != nil || err.Error() != "keycloak: token validation: "+want {
				t.Errorf("got Msg=%q Cause=%v Error()=%q, want Msg=%q and no cause", te.Msg, te.Cause, err.Error(), want)
			}
			if n := atomic.LoadInt32(f.fetches); n != 0 {
				t.Errorf("JWKS 요청 %d 건 — HS 는 키를 찾기 전에 거부해야 한다(0 건)", n)
			}
			// 허용 목록 밖이면 지금의 길과 문구 그대로다 — 핀이 먼저다.
			pinned := f.validator(t, time.Minute)
			if _, err := pinned.Validate(context.Background(), forged); !errors.As(err, &te) || !strings.HasPrefix(te.Msg, "parse: ") {
				t.Errorf("허용 목록 밖의 %s 는 핀(parse: )에서 거부돼야 한다: %v", alg, err)
			}
			// 대조 — 같은 검증기가 그 RSA 키로 서명한 RS256 토큰은 통과시키고, 그때 JWKS 를 한 번 부른다(계수기가 살아 있다).
			if _, err := v.Validate(context.Background(), f.sign(t, f.priv, "k1", cl)); err != nil {
				t.Fatalf("같은 검증기의 RS256 토큰이 거부됐다: %v", err)
			}
			if n := atomic.LoadInt32(f.fetches); n != 1 {
				t.Errorf("대조 뒤 JWKS 요청 %d 건 — 1 건이어야 한다", n)
			}
		})
	}
}
