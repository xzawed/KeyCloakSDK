package keycloak

import (
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
)

// tokenResponseMaxBytes caps every token-endpoint and introspection response body this SDK reads: the
// client_credentials, refresh_token and authorization_code grants, the admin lane's own token request, and the
// introspection response (and logout's, which shares its read). It counts the bytes the reader is handed —
// after the transport has decoded a Content-Encoding it asked for (net/http asks for and decodes gzip).
//
// 1 MiB is 16 times the longest bearer Keycloak 26.6 accepts with default settings (65,459 bytes; one more is
// HTTP 431), so the cap never refuses a token the server would take, while an endless body from a hostile or
// broken endpoint stops here. ⚠️ Do not borrow jwksMaxBytes (51,200): a service account's token grows with the
// realms it manages (456 bytes each, measured), and that value refused usable tokens of large deployments.
//
// ⚠️ A plain decimal literal on purpose — the nine SDKs share this value and a cross-language guard reads it.
const tokenResponseMaxBytes = 1048576

// errTokenResponseTooLarge is what a capped body's Read returns once the body is known to be longer than the cap.
// Its text is the SDK's own; it quotes nothing the server sent.
var errTokenResponseTooLarge = fmt.Errorf("token response exceeds %d bytes", tokenResponseMaxBytes)

// tokenCapKey marks the context of a request whose response is a token response. Only the SDK's own token
// requests carry it (oauthCtx and the admin token source), so the transport both lanes share caps exactly those
// and never an admin listing, which can legitimately be large.
type tokenCapKey int

// withTokenCap marks ctx for the cap and returns a flag that reports whether the cap refused the response. The
// flag is for the auth lane: x/oauth2 flattens the body's Read error into a string ("oauth2: cannot fetch
// token: …"), so the error it returns cannot say that the cap was the reason.
func withTokenCap(ctx context.Context) (context.Context, *atomic.Bool) {
	hit := new(atomic.Bool)
	return context.WithValue(ctx, tokenCapKey(0), hit), hit
}

// decodedGzip hands upward the decoded bytes of a gzip body net/http left encoded. net/http decodes only the gzip it asked
// for itself; a caller that sets Accept-Encoding — a consumer can, on the admin lane's resty client (Raw()) — gets the body
// as it came, and resty then gunzips it above every bound below it: measured, the token cap counted compressed bytes and
// accepted a small gzip token response that decodes to 16 MiB, and the admin error bound (adminbody.go) cut a gzip stream
// resty then failed to decode, so a 404 became a *TransportError. So it is decoded here, as net/http decodes the gzip it
// asked for: lazily (the gzip header is read at the first Read — a body nobody reads is not waited on), with the headers
// saying so afterwards. The match is resty's own (client.go: Content-Encoding gzip, any case); an empty body decodes to
// nothing, as in net/http's own reader, so resty's zero-length exception needs no copy here — and resty's own gunzip, which
// failed an empty body whose length was not zero (a HEAD answer, an empty chunked body) with io.EOF, no longer runs.
func decodedGzip(resp *http.Response, body io.ReadCloser) io.ReadCloser {
	if !strings.EqualFold(resp.Header.Get("Content-Encoding"), "gzip") {
		return body
	}
	resp.Header.Del("Content-Encoding")
	resp.Header.Del("Content-Length")
	resp.ContentLength = -1
	resp.Uncompressed = true
	return &gunzipBody{rc: body}
}

// gunzipBody decodes rc lazily, as net/http's own gzip reader does.
type gunzipBody struct {
	rc io.ReadCloser
	zr *gzip.Reader
}

func (b *gunzipBody) Read(p []byte) (int, error) {
	if b.zr == nil {
		zr, err := gzip.NewReader(b.rc)
		if err != nil {
			return 0, err
		}
		b.zr = zr
	}
	return b.zr.Read(p)
}

func (b *gunzipBody) Close() error { return b.rc.Close() }

// capTokenResponse wraps body in the cap when ctx carries the mark, and returns it as it is otherwise.
func capTokenResponse(ctx context.Context, body io.ReadCloser) io.ReadCloser {
	hit, ok := ctx.Value(tokenCapKey(0)).(*atomic.Bool)
	if !ok {
		return body
	}
	return &cappedBody{ReadCloser: body, hit: hit}
}

// cappedBody hands a token response to its reader (x/oauth2 or resty) and fails it once it is longer than
// tokenResponseMaxBytes. It never hands over more than the cap and never asks the body for more than cap+1
// bytes: each Read is trimmed to what is left, and the byte past the cap is a one-byte look-ahead taken by the
// Read that delivers the cap's last byte. It has to be taken there: x/oauth2 reads through
// io.LimitReader(body, 1<<20) and so never asks for byte cap+1 itself — measured before this type existed, a
// 1,048,577-byte body whose first MiB held a valid token was accepted.
type cappedBody struct {
	io.ReadCloser
	hit *atomic.Bool
	n   int64 // bytes handed over
	end error // what lies past the cap, once looked at: io.EOF, errTokenResponseTooLarge, or a read error
}

func (b *cappedBody) Read(p []byte) (int, error) {
	if b.end != nil {
		return 0, b.end
	}
	left := tokenResponseMaxBytes - b.n
	if left == 0 {
		return 0, b.lookPast()
	}
	if int64(len(p)) > left {
		p = p[:left]
	}
	k, err := b.ReadCloser.Read(p)
	b.n += int64(k)
	if err == nil && b.n == tokenResponseMaxBytes {
		err = b.lookPast()
	}
	return k, err
}

// lookPast reads the one byte after the cap. None (io.EOF) means the body is exactly as long as the cap; one means
// it is longer, and the response is refused. A read error is passed on as it is (it is already scrubbed).
func (b *cappedBody) lookPast() error {
	var one [1]byte
	if _, err := io.ReadFull(b.ReadCloser, one[:]); err != nil {
		b.end = err
	} else {
		b.hit.Store(true)
		b.end = errTokenResponseTooLarge
	}
	return b.end
}

// grantFailed is the *AuthError a grant method returns when x/oauth2 fails. capped and below are from oauthCtx: when
// the cap refused the token response, the message names the cap rather than a withheld lower-library detail; when a
// deadline ended the body read, x/oauth2 has flattened its error with %v and the cause is the one the transport kept.
func grantFailed(msg string, err error, capped *atomic.Bool, below *belowHTTPSlot) *AuthError {
	if capped.Load() {
		return &AuthError{Msg: msg + ": " + errTokenResponseTooLarge.Error(), Cause: errTokenResponseTooLarge}
	}
	if lost := below.lost(err); lost != nil {
		return &AuthError{Msg: msg, Cause: lost}
	}
	return &AuthError{Msg: msg, OAuthError: oauthError(err), Cause: scrubCause(err)}
}
