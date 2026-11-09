package keycloak

import (
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"unicode/utf8"
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

// errTokenResponseNotUTF8 is what a strict body's Read returns once a 2xx token response has a byte sequence that is not
// UTF-8 (RFC 8259 §8.1). encoding/json — x/oauth2's and resty's decoder — turns such a sequence into U+FFFD without an
// error, so the grants returned a token the IdP never issued as a success (measured 2026-11-10). The response arrived,
// so the class is *AuthError (registry token-response-class-divergent, decision D1).
var errTokenResponseNotUTF8 = errors.New("token response is not valid UTF-8")

// utf8Key marks the context of a token request whose 2xx body must be UTF-8. The flag it carries exists for the same
// reason as the cap's: x/oauth2 and gocloak flatten a body's Read error into a string, so the flag decides the class.
type utf8Key int

// withStrictUTF8 marks ctx for the UTF-8 check and returns the flag that reports whether the check refused the body.
func withStrictUTF8(ctx context.Context) (context.Context, *atomic.Bool) {
	bad := new(atomic.Bool)
	return context.WithValue(ctx, utf8Key(0), bad), bad
}

// strictUTF8 wraps a 2xx body in the check when ctx carries the mark — an error status is judged by its status, and its
// body is never decoded as a token.
func strictUTF8(ctx context.Context, status int, body io.ReadCloser) io.ReadCloser {
	bad, ok := ctx.Value(utf8Key(0)).(*atomic.Bool)
	if !ok || status < 200 || status >= 300 {
		return body
	}
	return &utf8Body{ReadCloser: body, bad: bad}
}

// utf8Body hands a body upward while checking that it is UTF-8, keeping the start of a sequence one Read cut in two
// until the next Read completes it. An invalid sequence — or a sequence still cut at EOF — fails the read **at EOF**:
// whether the body is unusable can only be said once it arrived in full. Refusing at the first bad byte turned a body
// that was then cut short or went over the cap — not arrived, *TransportError — into *AuthError on the grants while
// Introspect, which reads first and checks after, still said *TransportError (independent review leg, measured
// 2026-11-10). So a cap or read error from below passes through untouched, and the flag is set only at EOF.
type utf8Body struct {
	io.ReadCloser
	bad     *atomic.Bool
	tail    []byte // the start of a sequence the last Read cut in two (at most utf8.UTFMax-1 bytes)
	invalid bool   // a sequence that is not UTF-8 went by — refused if the body then ends
	end     error  // errTokenResponseNotUTF8 once refused
}

func (b *utf8Body) Read(p []byte) (int, error) {
	if b.end != nil {
		return 0, b.end
	}
	n, err := b.ReadCloser.Read(p)
	if !b.invalid && !b.take(p[:n]) {
		b.invalid = true
	}
	if errors.Is(err, io.EOF) && (b.invalid || len(b.tail) > 0) {
		b.bad.Store(true)
		b.end = errTokenResponseNotUTF8
		return 0, b.end
	}
	return n, err
}

// take checks chunk after what the previous Read left cut, and keeps the start of a sequence this one cuts.
func (b *utf8Body) take(chunk []byte) bool {
	buf := make([]byte, 0, len(b.tail)+len(chunk))
	buf = append(append(buf, b.tail...), chunk...)
	cut := len(buf)
	for i := len(buf) - 1; i >= 0 && i > len(buf)-utf8.UTFMax; i-- {
		if utf8.RuneStart(buf[i]) {
			if !utf8.FullRune(buf[i:]) {
				cut = i
			}
			break
		}
	}
	b.tail = buf[cut:]
	return utf8.Valid(buf[:cut])
}

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

// grantFailed is the error a grant method returns when x/oauth2 fails. A response that did not arrive in full is
// *TransportError — none came (refused, unreachable, a deadline before it), its body was cut short or ended by a deadline,
// or it went over the cap — and one that arrived but is not a usable token response is *AuthError (#935; it used to be
// *AuthError for all of them). Before the transport: a request that cannot be built (an unparsable token URL — Config
// accepts a realm like "%zz") is *TransportError, the class Introspect, Logout and the admin login give the same Config,
// while x/oauth2's own refusal (an empty refresh token) stays *AuthError — retrying it cannot help (#952 legs). capped and
// below are from oauthCtx: over the cap the message names the cap rather than a withheld lower-library detail; when a
// deadline ended the body read, x/oauth2 has flattened its error with %v and the cause is the one the transport kept.
// notUTF8 is oauthCtx's too: a 2xx body that is not UTF-8 arrived and is unusable — it is checked before below, whose
// arrival mark never sees the EOF the check withheld.
func grantFailed(msg string, err error, capped, notUTF8 *atomic.Bool, below *belowHTTPSlot) error {
	if capped.Load() {
		return &TransportError{Msg: msg + ": " + errTokenResponseTooLarge.Error(), Cause: errTokenResponseTooLarge}
	}
	if notUTF8.Load() {
		return &AuthError{Msg: msg + ": " + errTokenResponseNotUTF8.Error(), Cause: errTokenResponseNotUTF8}
	}
	if lost := below.lost(err); lost != nil {
		return &TransportError{Msg: msg, Cause: lost}
	}
	if !below.wasSent() {
		if ue := (*url.Error)(nil); errors.As(err, &ue) && ue.Op == "parse" {
			return &TransportError{Msg: msg, Cause: scrubCause(err)}
		}
	} else if !below.fullyArrived() {
		return &TransportError{Msg: msg, Cause: scrubCause(err)}
	}
	return &AuthError{Msg: msg, OAuthError: oauthError(err), Cause: scrubCause(err)}
}
