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
// (AuthError.OAuthError), so nothing the caller relies on is lost.
func scrubCause(err error) error {
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
		if oauthCodeShaped(re.ErrorCode) {
			msg += ", error " + strconv.Quote(re.ErrorCode)
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

// wireScrubTransport keeps bytes the server sent out of transport errors. net/http quotes what it could
// not parse — a reply that is not HTTP (`malformed HTTP response "<line>"`), a bad header or chunked
// trailer line (`malformed MIME header: missing colon: "<line>"`) — and that text reached callers
// through *url.Error, through x/oauth2, and flattened into gocloak's message. Both the RoundTrip error
// and the body's Read error pass through here; errors from beneath HTTP are returned as they are.
type wireScrubTransport struct{ base http.RoundTripper }

func (t wireScrubTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(req)
	if err != nil {
		return resp, scrubWire(err)
	}
	resp.Body = wireScrubBody{resp.Body}
	return resp, nil
}

// CloseIdleConnections lets http.Client.CloseIdleConnections reach the pooled transport (Close relies on it).
func (t wireScrubTransport) CloseIdleConnections() {
	if c, ok := t.base.(interface{ CloseIdleConnections() }); ok {
		c.CloseIdleConnections()
	}
}

type wireScrubBody struct{ io.ReadCloser }

// Read returns io.EOF itself (belowHTTP), so callers comparing err == io.EOF still see the end.
func (b wireScrubBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	return n, scrubWire(err)
}

// loginError is toSDKError for the admin lane's token request — the same classification (a status
// becomes *AdminError, none becomes *TransportError) without the IdP's words. gocloak flattens a
// failed token response into APIError.Message as "<status line>: <error>: <errorMessage>:
// <error_description>", so the parts cannot be told apart; the message is rebuilt from the status code
// and the first code-shaped part. On a refused redirect net/http names the redirect target, which the
// IdP chose — it is dropped the same way.
func loginError(err error) error {
	typ := fmt.Sprintf("%T", err)
	var apiErr *gocloak.APIError
	if errors.As(err, &apiErr) && apiErr.Code != 0 {
		msg := strconv.Itoa(apiErr.Code) + " " + http.StatusText(apiErr.Code)
		if parts := strings.Split(apiErr.Message, ": "); len(parts) > 1 {
			for _, p := range parts[1:] {
				if oauthCodeShaped(p) {
					msg += ": " + p
					break
				}
			}
		}
		return &AdminError{StatusCode: apiErr.Code, Msg: msg,
			Cause: &responseFreeError{typ: typ, msg: msg + " (response body withheld)"}}
	}
	msg := err.Error()
	if refused := ": " + errBackChannelRedirect.Error(); strings.HasSuffix(msg, refused) {
		head, _, _ := strings.Cut(msg, ": ")
		msg = head + refused + " (redirect target withheld)"
	}
	return &TransportError{Msg: msg, Cause: &responseFreeError{typ: typ, msg: msg}}
}
