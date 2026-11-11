package keycloak

import (
	"compress/flate"
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

// errTokenResponseUnpairedSurrogate is what a strict body's Read returns once a 2xx token response, read to its end, holds
// a \u escape of a UTF-16 surrogate without its pair — in a value or a member name (RFC 8259 §8.2 allows the grammar, I-JSON
// §2.1 forbids it). encoding/json turns it into U+FFFD without an error, so the grants returned a token whose bytes the IdP
// never sent (measured 2026-11-11). The response arrived, so the class is *AuthError (registry
// token-response-class-residue, decision Q2: anywhere in the body, the whole response).
var errTokenResponseUnpairedSurrogate = errors.New("token response holds an unpaired surrogate escape")

// errTokenResponseUndecodable is what a token response's Read returns once its gzip coding does not decode — a header that
// is not gzip, a corrupt deflate stream, a checksum or length that does not match. The bytes arrived, so the class is
// *AuthError (decision Q1, 2026-11-11 — it was *TransportError: the decoder's error counted as a cut body). A gzip stream
// cut short ends in io.ErrUnexpectedEOF instead, which cannot be told from a dropped connection and stays *TransportError.
var errTokenResponseUndecodable = errors.New("token response could not be decoded")

// undecodable reports whether err is a gzip decoder's verdict on bytes that arrived (undecodable · errTokenResponseUndecodable).
// Their texts are the decoder's own and quote nothing the server sent ("gzip: invalid header", "flate: corrupt input before
// offset 12"), so wireScrubBody passes them as they are. ⚠️ The verdict is on the bytes that came, at the first bad one —
// not on whether the rest of the body then arrives: no cut produces these errors (a cut is io.ErrUnexpectedEOF), and bytes
// that do not decode stay so on a retry. PHP's curl 61 (#1021), the JVM's ZipException and Python's zlib.error are judged
// the same way. It runs on every Read of every response (wireScrubBody), so a nil or io.EOF error returns before the
// errors.As target is taken — taking it moved one allocation per Read to the heap (independent review leg, measured).
func undecodable(err error) bool {
	if err == nil || err == io.EOF {
		return false
	}
	var corrupt flate.CorruptInputError
	return errors.Is(err, gzip.ErrHeader) || errors.Is(err, gzip.ErrChecksum) || errors.As(err, &corrupt)
}

// bodyRefusal records why the strict layers of a token request refused its body — errTokenResponseNotUTF8,
// errTokenResponseUnpairedSurrogate or errTokenResponseUndecodable, the first one wins. It exists for the same reason as
// the cap's flag: x/oauth2 and gocloak flatten a body's Read error into a string, so the record decides the class.
type bodyRefusal struct{ err atomic.Pointer[error] }

// refuse records err (unless an earlier refusal is recorded) and returns it; on a nil record it only returns err.
func (r *bodyRefusal) refuse(err error) error {
	if r != nil {
		r.err.CompareAndSwap(nil, &err)
	}
	return err
}

// reason is the recorded refusal, or nil.
func (r *bodyRefusal) reason() error {
	if r == nil {
		return nil
	}
	if p := r.err.Load(); p != nil {
		return *p
	}
	return nil
}

// strictKey marks the context of a token request whose body must be usable as it arrived: a 2xx body must be UTF-8 without
// an unpaired surrogate escape (strictBody), and no body's gzip coding may fail to decode (capTokenResponse).
type strictKey int

// withStrictBody marks ctx for the strict checks and returns the record of what they refused.
func withStrictBody(ctx context.Context) (context.Context, *bodyRefusal) {
	refused := new(bodyRefusal)
	return context.WithValue(ctx, strictKey(0), refused), refused
}

// strictBody wraps a 2xx body in the check when ctx carries the mark — an error status is judged by its status, and its
// body is never decoded as a token.
func strictBody(ctx context.Context, status int, body io.ReadCloser) io.ReadCloser {
	refused, ok := ctx.Value(strictKey(0)).(*bodyRefusal)
	if !ok || status < 200 || status >= 300 {
		return body
	}
	return &utf8Body{ReadCloser: body, refused: refused}
}

// utf8Body hands a body upward while checking that it is UTF-8, keeping the start of a sequence one Read cut in two
// until the next Read completes it, and that it holds no unpaired surrogate escape (surrogateScan, which follows the bytes
// Read by Read without keeping them). An invalid sequence — or a sequence still cut at EOF — or such an escape fails the
// read **at EOF**: whether the body is unusable can only be said once it arrived in full. Refusing at the first bad byte
// turned a body that was then cut short or went over the cap — not arrived, *TransportError — into *AuthError on the
// grants while Introspect, which reads first and checks after, still said *TransportError (independent review leg,
// measured 2026-11-10). So a cap or read error from below passes through untouched, and the refusal is recorded only at
// EOF.
type utf8Body struct {
	io.ReadCloser
	refused *bodyRefusal
	tail    []byte // the start of a sequence the last Read cut in two (at most utf8.UTFMax-1 bytes)
	scan    surrogateScan
	invalid bool  // a sequence that is not UTF-8 went by — refused if the body then ends
	end     error // the refusal, once refused
}

func (b *utf8Body) Read(p []byte) (int, error) {
	if b.end != nil {
		return 0, b.end
	}
	n, err := b.ReadCloser.Read(p)
	if !b.invalid && !b.take(p[:n]) {
		b.invalid = true
	}
	if !b.invalid {
		b.scan.feed(p[:n])
	}
	if errors.Is(err, io.EOF) {
		switch {
		case b.invalid || len(b.tail) > 0:
			b.end = b.refused.refuse(errTokenResponseNotUTF8)
		case b.scan.ended():
			b.end = b.refused.refuse(errTokenResponseUnpairedSurrogate)
		}
		if b.end != nil {
			return 0, b.end
		}
	}
	return n, err
}

// surrogateScan is holdsUnpairedSurrogate fed Read by Read. Keeping the body for the batch scanner raised what refusing a
// 16 MiB response allocates from under 6 MiB to over 9 (TestTokenResponseCapOnEveryLane, measured 2026-11-11). Its verdict
// equals the batch scanner's on every split of the same bytes (TestSurrogateScanAgreesWithTheBatchScanner).
type surrogateScan struct {
	state scanState
	hex   int // hex digits of the current \u escape read so far
	unit  int // their value
	found bool
}

type scanState uint8

const (
	scanOut      scanState = iota // outside a string
	scanIn                        // inside a string
	scanEscape                    // after '\' inside a string
	scanUnit                      // in the hex digits of \u
	scanPairEsc                   // a high surrogate escape ended: '\' must follow at once,
	scanPairU                     // then 'u',
	scanPairUnit                  // then the four hex digits of a low surrogate
)

func (s *surrogateScan) feed(chunk []byte) {
	for _, c := range chunk {
		if s.found {
			return
		}
		s.step(c)
	}
}

func (s *surrogateScan) step(c byte) {
	switch s.state {
	case scanOut:
		if c == '"' {
			s.state = scanIn
		}
	case scanIn:
		switch c {
		case '"':
			s.state = scanOut
		case '\\':
			s.state = scanEscape
		}
	case scanEscape:
		if c == 'u' {
			s.state, s.hex, s.unit = scanUnit, 0, 0
		} else {
			s.state = scanIn // a two-character escape — the escaped character is skipped
		}
	case scanUnit:
		v := hexDigit(c)
		if v < 0 {
			// a malformed escape — the parser's to refuse: the digits read so far are plain characters, and so is c
			s.state = scanIn
			s.step(c)
			return
		}
		if s.unit, s.hex = s.unit<<4|v, s.hex+1; s.hex < 4 {
			return
		}
		switch {
		case s.unit >= 0xDC00 && s.unit <= 0xDFFF:
			s.found = true // a low surrogate with no high one before it
		case s.unit >= 0xD800 && s.unit <= 0xDBFF:
			s.state = scanPairEsc
		default:
			s.state = scanIn
		}
	case scanPairEsc:
		s.state, s.found = scanPairU, c != '\\'
	case scanPairU:
		s.state, s.hex, s.unit, s.found = scanPairUnit, 0, 0, c != 'u'
	case scanPairUnit:
		v := hexDigit(c)
		if v < 0 {
			s.found = true
			return
		}
		if s.unit, s.hex = s.unit<<4|v, s.hex+1; s.hex == 4 {
			s.state, s.found = scanIn, s.unit < 0xDC00 || s.unit > 0xDFFF
		}
	}
}

// ended is the verdict once the body ended — a high surrogate escape still waiting for its low one is unpaired.
func (s *surrogateScan) ended() bool { return s.found || s.state >= scanPairEsc }

// holdsUnpairedSurrogate reports whether a JSON text holds a \u escape of a UTF-16 surrogate without its pair — a low one
// with no high before it, or a high one not followed at once by a low one — in a string value or a member name. It scans
// the bytes: escapes are ASCII and no byte of a multi-byte UTF-8 sequence equals '"' or '\'. A '\' escaped by another is
// not an escape, and a malformed escape is skipped and the scan goes on (the parser's to refuse; stopping there would miss
// what follows). The same scanner as the other eight (JVM holdsUnpairedSurrogate, python holds_unpaired_surrogate).
func holdsUnpairedSurrogate(json []byte) bool {
	inString := false
	for i := 0; i < len(json); i++ {
		c := json[i]
		switch {
		case !inString:
			inString = c == '"'
		case c == '"':
			inString = false
		case c == '\\' && i+1 < len(json):
			if json[i+1] != 'u' {
				i++ // a two-character escape — skip the escaped character
				continue
			}
			unit := hex4(json, i+2)
			if unit < 0 {
				i++ // a malformed escape — the parser's to refuse; go on past it
				continue
			}
			i += 5
			if unit >= 0xDC00 && unit <= 0xDFFF {
				return true // a low surrogate with no high one before it
			}
			if unit >= 0xD800 && unit <= 0xDBFF {
				low := -1
				if i+2 < len(json) && json[i+1] == '\\' && json[i+2] == 'u' {
					low = hex4(json, i+3)
				}
				if low < 0xDC00 || low > 0xDFFF {
					return true
				}
				i += 6
			}
		}
	}
	return false
}

// hex4 is the value of the four hex digits (either case) at json[at:], or -1.
func hex4(json []byte, at int) int {
	if at+4 > len(json) {
		return -1
	}
	v := 0
	for _, d := range json[at : at+4] {
		h := hexDigit(d)
		if h < 0 {
			return -1
		}
		v = v<<4 | h
	}
	return v
}

// hexDigit is the value of one hex digit (either case), or -1.
func hexDigit(d byte) int {
	switch {
	case d >= '0' && d <= '9':
		return int(d - '0')
	case d >= 'a' && d <= 'f':
		return int(d-'a') + 10
	case d >= 'A' && d <= 'F':
		return int(d-'A') + 10
	}
	return -1
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

// capTokenResponse wraps body in the cap when ctx carries the mark, and returns it as it is otherwise. The gzip decoders
// sit below it (net/http's under wireScrubBody, decodedGzip's above it), so it is also where a decoder's verdict on the
// bytes becomes errTokenResponseUndecodable — at any status: an error status is judged by its status, and its body
// arrived too (decision Q1).
func capTokenResponse(ctx context.Context, body io.ReadCloser) io.ReadCloser {
	hit, ok := ctx.Value(tokenCapKey(0)).(*atomic.Bool)
	if !ok {
		return body
	}
	refused, _ := ctx.Value(strictKey(0)).(*bodyRefusal)
	return &cappedBody{ReadCloser: body, hit: hit, refused: refused}
}

// cappedBody hands a token response to its reader (x/oauth2 or resty) and fails it once it is longer than
// tokenResponseMaxBytes. It never hands over more than the cap and never asks the body for more than cap+1
// bytes: each Read is trimmed to what is left, and the byte past the cap is a one-byte look-ahead taken by the
// Read that delivers the cap's last byte. It has to be taken there: x/oauth2 reads through
// io.LimitReader(body, 1<<20) and so never asks for byte cap+1 itself — measured before this type existed, a
// 1,048,577-byte body whose first MiB held a valid token was accepted.
type cappedBody struct {
	io.ReadCloser
	hit     *atomic.Bool
	refused *bodyRefusal
	n       int64 // bytes handed over
	end     error // what lies past the cap, once looked at: io.EOF, errTokenResponseTooLarge, or a read error
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
	if undecodable(err) {
		err = b.refused.refuse(errTokenResponseUndecodable)
	}
	if err == nil && b.n == tokenResponseMaxBytes {
		err = b.lookPast()
	}
	return k, err
}

// lookPast reads the one byte after the cap. None (io.EOF) means the body is exactly as long as the cap; one means
// it is longer, and the response is refused. A read error is passed on as it is (it is already scrubbed) — a
// decoder's verdict on the bytes as errTokenResponseUndecodable.
func (b *cappedBody) lookPast() error {
	var one [1]byte
	if _, err := io.ReadFull(b.ReadCloser, one[:]); err != nil {
		if undecodable(err) {
			err = b.refused.refuse(errTokenResponseUndecodable)
		}
		b.end = err
	} else {
		b.hit.Store(true)
		b.end = errTokenResponseTooLarge
	}
	return b.end
}

// introspectionRefusal is Introspect's error for a 2xx body that arrived but cannot be read as the JSON text it claims to
// be, or nil: not UTF-8 (RFC 8259 §8.1; decision D1, measured 2026-11-10) or holding an unpaired surrogate escape (decision
// Q2, measured 2026-11-11 — accepted) — encoding/json turns either into U+FFFD without an error, so the claims would be ones
// the IdP never sent. ⚠️ Kept out of auth.go: that file is pinned by the integration-only boundary coverage
// (scripts/integration-coverage.json), and no real Keycloak reaches these refusals.
func introspectionRefusal(body []byte) error {
	if !utf8.Valid(body) {
		return &AuthError{Msg: "introspection response is not valid UTF-8"}
	}
	if holdsUnpairedSurrogate(body) {
		return &AuthError{Msg: "introspection response holds an unpaired surrogate escape"}
	}
	return nil
}

// readFailed is postForm's error (Introspect · Logout) when reading the body failed. A gzip coding that does not decode
// arrived and is unusable — *AuthError at any status, as on the grants (decision Q1, 2026-11-11; it was *TransportError) —
// and anything else did not arrive in full: *TransportError, as before. Kept out of auth.go for the reason
// introspectionRefusal is.
func readFailed(endpoint string, err error) error {
	if undecodable(err) {
		return &AuthError{Msg: "response from " + endpoint + " could not be decoded"}
	}
	return &TransportError{Msg: err.Error(), Cause: err}
}

// grantFailed is the error a grant method returns when x/oauth2 fails. A response that did not arrive in full is
// *TransportError — none came (refused, unreachable, a deadline before it), its body was cut short or ended by a deadline,
// or it went over the cap — and one that arrived but is not a usable token response is *AuthError (#935; it used to be
// *AuthError for all of them). Before the transport: a request that cannot be built (an unparsable token URL — Config
// accepts a realm like "%zz") is *TransportError, the class Introspect, Logout and the admin login give the same Config,
// while x/oauth2's own refusal (an empty refresh token) stays *AuthError — retrying it cannot help (#952 legs). capped and
// below are from oauthCtx: over the cap the message names the cap rather than a withheld lower-library detail; when a
// deadline ended the body read, x/oauth2 has flattened its error with %v and the cause is the one the transport kept.
// refused is oauthCtx's too: a body that is not UTF-8, holds an unpaired surrogate escape or does not decode arrived and
// is unusable — it is checked before below, whose arrival mark never sees the EOF the check withheld.
func grantFailed(msg string, err error, capped *atomic.Bool, refused *bodyRefusal, below *belowHTTPSlot, sent ...string) error {
	if capped.Load() {
		return &TransportError{Msg: msg + ": " + errTokenResponseTooLarge.Error(), Cause: errTokenResponseTooLarge}
	}
	if why := refused.reason(); why != nil {
		return &AuthError{Msg: msg + ": " + why.Error(), Cause: why}
	}
	if lost := below.lost(err); lost != nil {
		return &TransportError{Msg: msg, Cause: lost}
	}
	if !below.wasSent() {
		if ue := (*url.Error)(nil); errors.As(err, &ue) && ue.Op == "parse" {
			return &TransportError{Msg: msg, Cause: scrubCause(err, sent...)}
		}
	} else if !below.fullyArrived() {
		return &TransportError{Msg: msg, Cause: scrubCause(err, sent...)}
	}
	return &AuthError{Msg: msg, OAuthError: oauthError(err, sent...), Cause: scrubCause(err, sent...)}
}
