package keycloak

import (
	"bytes"
	"context"
	"io"
	"net/http"
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

// adminBodyTransport bounds what the admin lane reads of a response body. resty reads every body to its end before gocloak
// looks at it — measured (2026-10-25, the registry's admin-response-body-unbounded rescan): a create whose 201 carried
// 64 MiB was read in full, a 404 with 64 MiB was read in full (165 MB allocated by one call), and a 201 whose body stalled
// after the headers turned a create that already had its Location into a *TransportError at the read timeout. So the end
// is set here, below resty:
//   - an error body (status 3xx and up) is read here, at most one byte past adminErrorBodyMaxBytes (boundError);
//   - a 2xx answering a facade call marked by withoutBody ends at once;
//   - any other success body is left as it is.
//
// A body closed before its end is read no further: on HTTP/1.1 net/http drops the connection rather than drain it, on
// HTTP/2 it resets only that stream. The admin token request's error body passes this bound and the token cap
// (tokencap.go) both: the two are equal, and the token cap looks one byte past its cap within the read that reaches it, so
// it still refuses an oversized one. ⚠️ Lowering this bound below the token cap would turn that refusal into a cut.
type adminBodyTransport struct{ base http.RoundTripper }

func (t adminBodyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(req)
	if err != nil || resp.Body == nil {
		return resp, err
	}
	switch {
	case resp.StatusCode >= 300:
		boundError(resp)
	case req.Context().Value(adminNoBodyKey(0)) != nil:
		resp.Body = endedBody{resp.Body}
	}
	return resp, nil
}

// boundError reads an error body to its end or one byte past the cap, so what resty is handed is settled before it looks.
// A body past the cap is cut to the cap and loses its media type. ⚠️ Cutting alone is not enough: resty parses a JSON
// error body into gocloak's error value, a cut one fails that parse, and gocloak then reports the parse failure instead of
// the status — measured, a 404 whose 2 MiB JSON body was cut came back as a *TransportError, so ErrNotFound stopped
// matching. Without a media type resty parses nothing and the answer keeps its status. A read error (the token cap's
// refusal, a timeout) becomes the error of the body resty reads.
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
