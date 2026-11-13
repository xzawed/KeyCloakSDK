package keycloak

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/Nerzal/gocloak/v13"
	"golang.org/x/oauth2"
)

// The IdP's words never become an SDK error's words — not in the message, and not in the cause chain
// a caller walks with errors.Unwrap/errors.As. Lower libraries quote what the server sent: x/oauth2's
// *RetrieveError prints a failed response's whole body or its error_description, its parse failures
// flatten encoding/json errors that quote the offending value, net/http quotes a line it could not
// parse, and gocloak flattens a token error body into its message. A hostile or broken IdP (or a proxy
// in front of it) can put live tokens in any of those. Measured before this file existed: 45 of 83
// hostile token/introspect cases printed a token (malformed_response_cause_test.go).
//
// Three places, one rule — the SDK builds the text from what it knows (the lower type, the HTTP status,
// a code-shaped OAuth error) and withholds the rest:
//   - scrubCause: the cause the auth lane attaches in place of an x/oauth2 error.
//   - wireScrubTransport: the transport both lanes use, so wire bytes never enter a transport error.
//   - loginError: the admin lane's token request, whose error gocloak has already flattened to a string.

// responseFreeError stands in for a lower-library error whose text can carry the IdP's response. It
// keeps the lower type's name (for debugging) and a summary the SDK wrote.
type responseFreeError struct {
	typ string // the lower error's dynamic type, e.g. "*oauth2.RetrieveError"
	msg string
}

func (e *responseFreeError) Error() string { return e.typ + ": " + e.msg }

const withheldNote = " (detail withheld: it can quote the IdP's response)"

// scrubCause is what the auth lane attaches as an SDK error's Cause instead of an x/oauth2 error.
// Transport failures (*url.Error) and errors from beneath HTTP stay as they are — wireScrubTransport
// already withheld what net/http quotes, and keeping them keeps errors.Is(err, context.DeadlineExceeded)
// and errors.As(err, &net.Error) working. The OAuth error code is read from the original before this
// (AuthError.OAuthError, vetted against what the request sent), so nothing the caller relies on is lost.
func scrubCause(err error, sent ...string) error {
	var ue *url.Error
	var re *oauth2.RetrieveError
	switch {
	case err == nil, errors.As(err, &ue), belowHTTP(err):
		return err
	case errors.As(err, &re):
		msg := "token endpoint answered"
		if re.Response != nil {
			msg += " HTTP " + strconv.Itoa(re.Response.StatusCode)
		}
		// The same rule as the field (oauthErrorCode against what the request sent) — the shape alone let a code-shaped
		// echo of the secret ride here (measured 2026-11-11).
		if code := oauthErrorCode(re.ErrorCode, sent...); code != "" {
			msg += ", error " + strconv.Quote(code)
		}
		return &responseFreeError{typ: fmt.Sprintf("%T", re), msg: msg + " (response body and error_description withheld)"}
	}
	return withheld(err)
}

// withheld keeps a lower error's type and its own opening words, and drops what it wrapped after them.
func withheld(err error) *responseFreeError {
	msg, cut := ownWords(err.Error())
	if cut {
		msg += withheldNote
	}
	return &responseFreeError{typ: fmt.Sprintf("%T", err), msg: msg}
}

// ownWords cuts a Go error string down to the words its package wrote. Go errors read
// "pkg: what happened: <wrapped detail>", and the detail is where response bytes get quoted — so the
// text stops before the second clause (before the first, when it does not open with a package name).
// A kept part that still quotes something or spans lines is dropped whole.
func ownWords(msg string) (string, bool) {
	kept := msg
	if head, rest, ok := strings.Cut(msg, ": "); ok {
		kept = head
		if isPkgName(head) {
			what, _, _ := strings.Cut(rest, ": ")
			kept = head + ": " + what
		}
	}
	if strings.ContainsAny(kept, "\"\n") {
		return "message withheld", true
	}
	return kept, kept != msg
}

func isPkgName(s string) bool {
	for _, r := range s {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && !strings.ContainsRune("/._-", r) {
			return false
		}
	}
	return s != ""
}

// oauthCodeShaped reports whether s looks like an RFC 6749 error code. Every registered code, and every
// code Keycloak sends, is lowercase letters and underscores; a token is not — it carries digits,
// capitals or dots. Anything else is withheld rather than guessed at.
// ⚠️ The boundary is the shape, not the meaning: a server string of only [a-z_] passes wherever it
// sits (the `error` field, a code-shaped description segment, a hostile reason phrase — Grok leg,
// measured). That is the price of keeping the code; a JWT never has the shape, and a random token of
// 10+ base64url characters has it with probability at most (27/64)^10 ≈ 2e-4.
func oauthCodeShaped(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, r := range s {
		if (r < 'a' || r > 'z') && r != '_' {
			return false
		}
	}
	return true
}

// oauthErrorCode is what AuthError.OAuthError carries for the server's `error` value s: s itself when it is shaped like
// an OAuth error code (oauthCodeShaped) and overlaps no non-empty secret the request sent — neither contains the other,
// so a truncated or extended echo is withheld too — and "" (no code) otherwise. It never trims a value into a code
// ("invalid_client\r\n" is no code). ⚠️ `error` is response body too: an endpoint that echoes what it got puts the
// client secret, the refresh token or the code there. The field used to take the RFC 6749 §5.2 grammar (1*NQSCHAR, as
// .NET #710), which a Keycloak-style secret, a JWT and a form-encoded secret all are, and a lowercase-only secret has
// the code shape itself (measured 2026-11-11: oauth_error_code_echo_test.go). The price of the overlap: a secret that is
// a piece of a registered code ("client") withholds that code. An absent secret ("") is not compared — it is a piece
// of every code.
func oauthErrorCode(s string, sent ...string) string {
	if !oauthCodeShaped(s) {
		return ""
	}
	for _, secret := range sent {
		if secret != "" && (strings.Contains(s, secret) || strings.Contains(secret, s)) {
			return ""
		}
	}
	return s
}

// belowHTTP reports whether err failed beneath HTTP — socket, DNS, TLS, timeout, cancellation, EOF.
// Those carry no bytes of a response, and callers match them with errors.Is/As, so they pass unchanged.
func belowHTTP(err error) bool {
	var ne net.Error
	var cv *tls.CertificateVerificationError
	var rh tls.RecordHeaderError
	return errors.As(err, &ne) || errors.Is(err, context.Canceled) ||
		errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) ||
		errors.As(err, &cv) || errors.As(err, &rh)
}

func scrubWire(err error) error {
	if err == nil || belowHTTP(err) {
		return err
	}
	return withheld(err)
}

// belowHTTPKey marks the context of an SDK call whose lower library turns the transport's error into text: the grants
// (x/oauth2 formats a token body's Read error with %v), the admin lane's login and its facade calls (gocloak folds every
// request error into APIError.Message). Without it a deadline that ends the exchange after the headers — the caller's, or
// the SDK's read timeout — loses errors.Is(err, context.DeadlineExceeded), which scrubCause above promises. Measured
// 2026-10-27: false for the three grants mid-body and for every admin call, true for Introspect and Validate, which keep
// the error themselves.
type belowHTTPKey int

// belowHTTPSlot keeps the first such error a request of the marked call meets, for the SDK error to carry as its cause.
// It also records whether the call's last request got its response in full (arrived · cut), which is what decides the
// error class: a response that arrived but is unusable is *AuthError, one that did not arrive is *TransportError (#935).
type belowHTTPSlot struct {
	err atomic.Pointer[error]
	// sent: the call reached the transport at all — a failure without it (x/oauth2 refusing an empty refresh token) sent
	// nothing, and stays *AuthError. arrived: the last request got a response (status line and headers). cut: a Read of
	// that response's body ended in an error that is not io.EOF — the transport, a deadline, broken framing, the size cap,
	// or a gzip stream cut short. ⚠️ A gzip body that does not decode is NOT counted here as the decider: a token request
	// records it as a refusal (tokencap.go errTokenResponseUndecodable — *AuthError, decision Q1, 2026-11-11), which
	// grantFailed · loginError read first. deflate and br are not decoded and arrive as raw bytes that fail as JSON
	// (*AuthError) — rust draws the same line (#951/#952 independent legs). status: the last response's code.
	sent, arrived, cut atomic.Bool
	status             atomic.Int64
	// first3xx: the first 3xx any request of the marked call was answered with. began does not reset it (it resets arrived,
	// cut and status), so a later 2xx of the same call — a retry a consumer turned on through Raw() — cannot hide it. Only
	// the admin facade's call reads it (answered3xx), and a token request never lands in a facade call's slot: the facade
	// fetches its token before call marks the ctx, and the SDK's own login marks a slot of its own.
	first3xx atomic.Int64
}

// began starts the arrival record of a new request — the class follows the call's last request.
func (s *belowHTTPSlot) began() {
	if s != nil {
		s.sent.Store(true)
		s.arrived.Store(false)
		s.cut.Store(false)
		s.status.Store(0)
	}
}

// wasSent reports whether any request of the marked call reached the transport.
func (s *belowHTTPSlot) wasSent() bool { return s != nil && s.sent.Load() }

// answered3xx is the error of an admin facade call that gocloak reports as a success although a request of the call was
// answered with a 3xx (first3xx), and nil otherwise; s is the slot call marked, never nil. gocloak's only error test is
// resty's IsError() (status > 399) and resty binds a result only for a 2xx, so a 3xx that net/http returned instead of
// following came back as a zero value and nil: Users.Get an empty *User, Search no users, Create the id "", Update and
// Delete nil (measured 2026-11-13 on 24 of the 25 facade calls; Realms.Update checked 2xx itself). net/http follows only a
// 301, 302, 303, 307 or 308 that carries a Location — and those the admin lane's errOnRedirect refuses, an error before
// this — and returns every other 3xx as it is, a 300 with a Location included. The error is a *gocloak.APIError with that
// status, so toSDKError classifies it as it does a 404 — an *AdminError carrying the code. The message is the SDK's (the
// code and Go's status text), never the server's reason phrase or body.
func (s *belowHTTPSlot) answered3xx() error {
	code := int(s.first3xx.Load())
	if code == 0 {
		return nil
	}
	return &gocloak.APIError{Code: code, Message: "answered " + strings.TrimSpace(strconv.Itoa(code)+" "+http.StatusText(code)) +
		", and a 3xx is not a success (the admin lane follows no redirect)"}
}

// fullyArrived reports whether the marked call's last request got a response whose body was not cut short. ⚠️ Not "the
// slot is empty": the slot keeps only errors from beneath HTTP and the context's, so broken chunked framing leaves it empty,
// and a connection closed before any response leaves it empty too — arrival is recorded positively instead.
func (s *belowHTTPSlot) fullyArrived() bool {
	return s != nil && s.arrived.Load() && !s.cut.Load()
}

// withBelowHTTP marks ctx and returns its slot.
func withBelowHTTP(ctx context.Context) (context.Context, *belowHTTPSlot) {
	s := new(belowHTTPSlot)
	return context.WithValue(ctx, belowHTTPKey(0), s), s
}

// belowHTTPSlotOf is the slot ctx carries, or nil.
func belowHTTPSlotOf(ctx context.Context) *belowHTTPSlot {
	s, _ := ctx.Value(belowHTTPKey(0)).(*belowHTTPSlot)
	return s
}

// keep records err (already scrubbed) when it ended a request of the marked call. ⚠️ A request whose context is done, or
// whose deadline has passed, records the context's error, not err: net/http enforces Client.Timeout on a transport it does
// not know (this one) with a context deadline **and** a Request.Cancel timer for the same instant, so the error the read
// sees is "context deadline exceeded" or the plain string "net/http: request canceled", by whichever timer fires first —
// and when Request.Cancel wins, ctx.Err() can still be nil for a moment (measured: with a ctx.Err() check alone, 3 of the
// 190 read-timeout cases in ten runs of cancel_identity_test.go lost the identity). Otherwise only an error from beneath
// HTTP is kept — anything else is withheld text that names no condition. io.EOF is the normal end.
func (s *belowHTTPSlot) keep(ctx context.Context, err error) {
	if s == nil || err == nil || errors.Is(err, io.EOF) {
		return
	}
	if cerr := ctx.Err(); cerr != nil {
		err = cerr
	} else if dl, ok := ctx.Deadline(); ok && !time.Now().Before(dl) {
		err = context.DeadlineExceeded
	} else if !belowHTTP(err) {
		return
	}
	s.err.CompareAndSwap(nil, &err)
}

// lost is the kept error when err — what the lower library returned — no longer carries it, and nil otherwise (nothing
// was kept, or err still answers errors.Is for it: a request refused before any response reaches x/oauth2 as *url.Error).
func (s *belowHTTPSlot) lost(err error) error {
	if s == nil {
		return nil
	}
	p := s.err.Load()
	if p == nil || errors.Is(err, *p) {
		return nil
	}
	return *p
}

// wireScrubTransport keeps bytes the server sent out of transport errors. net/http quotes what it could
// not parse — a reply that is not HTTP (`malformed HTTP response "<line>"`), a bad header or chunked
// trailer line (`malformed MIME header: missing colon: "<line>"`) — and that text reached callers
// through *url.Error, through x/oauth2, and flattened into gocloak's message. Both the RoundTrip error
// and the body's Read error pass through here; errors from beneath HTTP are returned as they are.
// It is also where a token response gets its size cap (tokencap.go) — both lanes' token requests pass here — and where a
// gzip body net/http left encoded is decoded first, so every bound above counts decoded bytes (decodedGzip).
type wireScrubTransport struct{ base http.RoundTripper }

func (t wireScrubTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	ctx := req.Context()
	slot := belowHTTPSlotOf(ctx)
	slot.began()
	resp, err := t.base.RoundTrip(req)
	if err != nil {
		err = scrubWire(err)
		slot.keep(ctx, err)
		return resp, err
	}
	resp.Body = strictBody(ctx, resp.StatusCode, capTokenResponse(ctx, decodedGzip(resp, wireScrubBody{ReadCloser: resp.Body, ctx: ctx, slot: slot})))
	if slot != nil {
		slot.arrived.Store(true)
		slot.status.Store(int64(resp.StatusCode))
		if resp.StatusCode >= 300 && resp.StatusCode < 400 {
			slot.first3xx.CompareAndSwap(0, int64(resp.StatusCode))
		}
		resp.Body = arrivalBody{ReadCloser: resp.Body, slot: slot}
	}
	return resp, nil
}

// arrivalBody is the outermost body of a marked call's response: a Read error that is not io.EOF means the response did
// not arrive in full, whichever layer ended it (the transport, the size cap, the gzip decoder) — see belowHTTPSlot.cut.
type arrivalBody struct {
	io.ReadCloser
	slot *belowHTTPSlot
}

func (b arrivalBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if err != nil && !errors.Is(err, io.EOF) && b.slot != nil {
		b.slot.cut.Store(true)
	}
	return n, err
}

// CloseIdleConnections lets http.Client.CloseIdleConnections reach the pooled transport (Close relies on it).
func (t wireScrubTransport) CloseIdleConnections() {
	if c, ok := t.base.(interface{ CloseIdleConnections() }); ok {
		c.CloseIdleConnections()
	}
}

// wireScrubBody scrubs the body's Read errors and keeps the one that ended a marked call's request in its slot (keep).
type wireScrubBody struct {
	io.ReadCloser
	ctx  context.Context
	slot *belowHTTPSlot
}

// Read returns io.EOF itself (belowHTTP), so callers comparing err == io.EOF still see the end. A gzip decoder's verdict on
// the bytes (net/http's reader sits below this body) passes as it is too — its text is the decoder's own and quotes nothing
// the server sent, and the token cap above turns it into errTokenResponseUndecodable (tokencap.go, decision Q1).
func (b wireScrubBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if undecodable(err) {
		return n, err
	}
	err = scrubWire(err)
	b.slot.keep(b.ctx, err)
	return n, err
}

// loginError is the error of the admin lane's token request, without the IdP's words. A response that arrived in full is
// *AuthError whatever its status, and one that did not (none came, its body was cut short or ended by a deadline, or it
// went over the cap) is *TransportError — the grant lane's classes (grantFailed, #935). ⚠️ **Never *AdminError**: its Is
// matches a token endpoint's 404 · 403 · 409 against ErrNotFound · ErrForbidden · ErrConflict, so a failed token refresh
// read as "the user is gone" with no admin request sent (measured 2026-11-05 — TestAdminTokenFailureNeverMatchesAdminSentinels;
// it was *AdminError for a status and *TransportError without one, a refused redirect included). gocloak flattens a failed
// token response into APIError.Message as "<status line>: <error>: <errorMessage>: <error_description>", so the parts cannot
// be told apart; the message is rebuilt from the status code and the first part oauthErrorCode lets through against what
// the login sent (sent — an echoed lowercase secret is code-shaped: it reached Msg, measured 2026-11-11) — in Msg only,
// never in OAuthError, because which part it is cannot be told. On a refused redirect net/http names the redirect
// target, which the IdP chose — it is dropped the same way. Without a status, the cause is the error the transport kept
// in below when gocloak dropped it (a deadline that ended the exchange), so errors.Is still finds it.
func loginError(err error, capped *atomic.Bool, strict *bodyRefusal, below *belowHTTPSlot, sent ...string) error {
	typ := fmt.Sprintf("%T", err)
	// A body that is not UTF-8, holds an unpaired surrogate escape or does not decode arrived and is unusable (tokencap.go)
	// — checked first, because the check withheld the EOF that below's arrival mark waits for.
	if why := strict.reason(); why != nil && !capped.Load() {
		msg := "client-credentials login failed: " + why.Error()
		return &AuthError{Msg: msg, Cause: &responseFreeError{typ: typ, msg: msg}}
	}
	var apiErr *gocloak.APIError
	if errors.As(err, &apiErr) && apiErr.Code != 0 && !capped.Load() {
		msg := "client-credentials login failed: HTTP " + strconv.Itoa(apiErr.Code) + " " + http.StatusText(apiErr.Code)
		if parts := strings.Split(apiErr.Message, ": "); len(parts) > 1 {
			for _, p := range parts[1:] {
				if oauthErrorCode(p, sent...) != "" {
					msg += ": " + p
					break
				}
			}
		}
		return &AuthError{Msg: msg, Cause: &responseFreeError{typ: typ, msg: msg + " (response body withheld)"}}
	}
	msg := err.Error()
	refused := ": " + errBackChannelRedirect.Error()
	redirect := strings.HasSuffix(msg, refused)
	if redirect {
		head, _, _ := strings.Cut(msg, ": ")
		msg = head + refused + " (redirect target withheld)"
	}
	if lost := below.lost(err); lost != nil {
		return &TransportError{Msg: msg, Cause: lost}
	}
	// No status from gocloak, but the response came in full — a body that is not the token JSON (gocloak drops the status
	// when resty cannot decode a JSON-labelled error body, so a 503 page labelled JSON lands here), or a redirect this lane
	// refuses. The status is the slot's; gocloak's words are not kept — the decoder quotes a number it could not fit
	// (measured: "cannot unmarshal number 98765432109876543210987654321 into Go struct field JWT.expires_in").
	if !capped.Load() && below.fullyArrived() {
		status := int(below.status.Load())
		amsg := "client-credentials login failed: HTTP " + strconv.Itoa(status) + " " + http.StatusText(status)
		if redirect {
			amsg += refused + " (redirect target withheld)"
		} else {
			amsg += ": unusable token response (body withheld)"
		}
		return &AuthError{Msg: amsg, Cause: &responseFreeError{typ: typ, msg: amsg}}
	}
	return &TransportError{Msg: msg, Cause: &responseFreeError{typ: typ, msg: msg}}
}
