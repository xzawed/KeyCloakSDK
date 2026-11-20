package keycloak

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"sync/atomic"

	"github.com/Nerzal/gocloak/v13"
)

// adminErrorBodyMaxBytes caps the error body (status 3xx and up) the admin lane reads. gocloak reads an error body only to
// build an error message, so it borrows the token-response cap. Success bodies (listings) are not capped — they are
// legitimately large.
const adminErrorBodyMaxBytes = tokenResponseMaxBytes

// adminNoBodyKey marks the context of a facade call that reads no success body: Create reads only the Location header,
// Update and Delete read nothing. Only the facade sets it (withoutBody). ⚠️ It is not a rule on the response's shape:
// gocloak methods a Raw() consumer can call do read such bodies — CreateClientRepresentation binds a 201's body (the
// created client) and UpdateGroupManagementPermissions binds a PUT's 200 — so ending every 201 or PUT answer broke them.
type adminNoBodyKey int

// withoutBody marks ctx for a facade call that reads no success body.
func withoutBody(ctx context.Context) context.Context {
	return context.WithValue(ctx, adminNoBodyKey(0), true)
}

// loginBodyKey marks the context of the admin lane's own token request — newAdminClient's token source sets it, nothing
// else does. adminBodyTransport reads that request's 2xx body itself (readLoginBody) and records the OAuth `error` member
// in it: gocloak binds a 2xx into its JWT, which has no field for `error`, so a token response carrying one came back as a
// success — with its access token when it held one, which the admin request then carried (registry
// auth-2xx-error-code-divergent, measured on main 350836b9).
type loginBodyKey int

// loginBody is the record of the admin login's last response: what readLoginBody found when it was a 2xx whose body carries
// an OAuth `error` (oauthErrorMember, tokencap.go), and nil otherwise. It follows the last request, as belowHTTPSlot does —
// RoundTrip clears it before each.
type loginBody struct {
	found atomic.Pointer[loginErrorBody]
}

// loginErrorBody is such a 2xx: its status, the `error` member's value, and the message gocloak builds for a status that
// carries an error — the status, then the error, errorMessage and error_description members (gocloak's
// HTTPErrorResponse), joined by ": " — which loginStatusError (cause.go) reads as it reads gocloak's.
type loginErrorBody struct {
	status         int
	value, message string
}

// withLoginBody marks ctx as the admin login's and returns its record.
func withLoginBody(ctx context.Context) (context.Context, *loginBody) {
	kept := new(loginBody)
	return context.WithValue(ctx, loginBodyKey(0), kept), kept
}

// clear forgets the last response's record; a request that is not the admin login's has none (nil).
func (k *loginBody) clear() {
	if k != nil {
		k.found.Store(nil)
	}
}

// readLoginBody reads the admin login's 2xx body here, as boundError reads an error body — at most one byte past the token
// cap, which the cap below has refused by then (tokencap.go) — so the OAuth `error` member gocloak's JWT drops can be
// seen, and records it in kept; resty is then handed the same bytes. A read error becomes the error of the body resty
// reads, as in boundError, so loginError judges it as before. Reading here rather than recording what resty reads keeps a
// refused 16 MiB body to one copy of the cap (TestTokenResponseCapOnEveryLane bounds what refusing it allocates).
func readLoginBody(resp *http.Response, kept *loginBody) {
	b, err := io.ReadAll(io.LimitReader(resp.Body, tokenResponseMaxBytes+1))
	_ = resp.Body.Close()
	if err != nil {
		resp.Body = io.NopCloser(failedRead{err})
		return
	}
	if value, ok := oauthErrorMember(b); ok {
		// The members gocloak reads from an error body; one of another type is skipped, as gocloak's decoder skips it.
		var e gocloak.HTTPErrorResponse
		_ = json.Unmarshal(b, &e)
		kept.found.Store(&loginErrorBody{status: resp.StatusCode, value: value,
			message: strconv.Itoa(resp.StatusCode) + ": " + e.String()})
	}
	resp.Body = io.NopCloser(bytes.NewReader(b))
}

// adminBodyTransport bounds what the admin lane reads of a response body. resty reads every body to its end before gocloak
// looks at it — measured (2026-10-25, the registry's admin-response-body-unbounded rescan): a create whose 201 carried
// 64 MiB was read in full, a 404 with 64 MiB was read in full (165 MB allocated by one call), and a 201 whose body stalled
// after the headers turned a create that already had its Location into a *TransportError at the read timeout. So the end
// is set here, below resty:
//   - an error body (status 3xx and up) is read here, at most one byte past adminErrorBodyMaxBytes (boundError);
//   - a 2xx answering a facade call marked by withoutBody ends at once;
//   - a 2xx answering the admin login (marked by withLoginBody) is read here too, so its OAuth `error` can be seen
//     (readLoginBody);
//   - any other success body is left as it is.
//
// A body closed before its end is read no further: on HTTP/1.1 net/http drops the connection rather than drain it, on
// HTTP/2 it resets only that stream. The admin token request's error body passes this bound and the token cap
// (tokencap.go) both: the two are equal, and the token cap looks one byte past its cap within the read that reaches it, so
// it still refuses an oversized one. ⚠️ Lowering this bound below the token cap would turn that refusal into a cut.
type adminBodyTransport struct{ base http.RoundTripper }

func (t adminBodyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	kept, _ := req.Context().Value(loginBodyKey(0)).(*loginBody)
	kept.clear() // the record follows the login's last request
	resp, err := t.base.RoundTrip(req)
	if err != nil || resp.Body == nil {
		return resp, err
	}
	switch {
	case resp.StatusCode >= 300:
		boundError(resp)
	case req.Context().Value(adminNoBodyKey(0)) != nil:
		resp.Body = endedBody{resp.Body}
	case kept != nil:
		readLoginBody(resp, kept)
	}
	return resp, nil
}

// boundError reads an error body to its end or one byte past the cap, so what resty is handed is settled before it looks.
// A body past the cap is cut to the cap and loses its media type. ⚠️ Cutting alone is not enough: resty parses a JSON
// error body into gocloak's error value, a cut one fails that parse, and gocloak then reports the parse failure instead of
// the status — measured, a 404 whose 2 MiB JSON body was cut came back as a *TransportError, so ErrNotFound stopped
// matching. Without a media type resty parses nothing and the answer keeps its status. A read error (the token cap's
// refusal, a timeout) becomes the error of the body resty reads. The bytes counted are decoded ones — a gzip body net/http
// left encoded was decoded below this transport (decodedGzip).
func boundError(resp *http.Response) {
	b, err := io.ReadAll(io.LimitReader(resp.Body, adminErrorBodyMaxBytes+1))
	_ = resp.Body.Close()
	if err != nil {
		resp.Body = io.NopCloser(failedRead{err})
		return
	}
	if len(b) > adminErrorBodyMaxBytes {
		b = b[:adminErrorBodyMaxBytes]
		resp.Header.Del("Content-Type")
	}
	resp.Body = io.NopCloser(bytes.NewReader(b))
}

// failedRead is a body whose every Read fails with err.
type failedRead struct{ err error }

func (r failedRead) Read([]byte) (int, error) { return 0, r.err }

// CloseIdleConnections lets http.Client.CloseIdleConnections reach the pooled transport, as wireScrubTransport does.
func (t adminBodyTransport) CloseIdleConnections() {
	if c, ok := t.base.(interface{ CloseIdleConnections() }); ok {
		c.CloseIdleConnections()
	}
}

// endedBody reports the end at once without asking the body for anything. Close closes the body.
type endedBody struct{ io.ReadCloser }

func (endedBody) Read([]byte) (int, error) { return 0, io.EOF }
