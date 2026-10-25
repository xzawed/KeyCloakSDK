package keycloak

import (
	"io"
	"net/http"
)

// adminErrorBodyMaxBytes caps the error body (status 3xx and up) the admin lane reads. gocloak reads an error body only to
// build an error message, so it borrows the token-response cap. Success bodies (listings) are not capped — they are
// legitimately large.
const adminErrorBodyMaxBytes = tokenResponseMaxBytes

// adminBodyTransport bounds what the admin lane reads of a response body. resty reads every body to its end before gocloak
// looks at it — measured (2026-10-25, the registry's admin-response-body-unbounded rescan): a create whose 201 carried
// 64 MiB was read in full, a 404 with 64 MiB was read in full (165 MB allocated by one call), and a 201 whose body stalled
// after the headers turned a create that already had its Location into a *TransportError at the read timeout. So the end
// is set here, below resty:
//   - a 2xx no admin call reads — 201, the answer to a PUT or a DELETE, or one with no media type — ends at once (a 204
//     needs no rule: net/http already hands it over as http.NoBody);
//   - an error body (status 3xx and up) ends at adminErrorBodyMaxBytes;
//   - any other success body is left as it is.
//
// Closing a body before its end makes net/http drop the connection rather than read the rest (it never drains), so a cut
// connection is not reused and costs nothing more. The SDK's own token requests (tokenCapKey) are left to the token cap: it
// must see byte cap+1 to refuse, so ending them at the cap here would accept an oversized token response.
type adminBodyTransport struct{ base http.RoundTripper }

func (t adminBodyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(req)
	if err != nil || resp.Body == nil || req.Context().Value(tokenCapKey(0)) != nil {
		return resp, err
	}
	switch {
	case resp.StatusCode >= 300:
		resp.Body = &endedBody{rc: resp.Body, left: adminErrorBodyMaxBytes}
	case resp.StatusCode == http.StatusCreated, req.Method == http.MethodPut, req.Method == http.MethodDelete,
		resp.Header.Get("Content-Type") == "":
		resp.Body = &endedBody{rc: resp.Body}
	}
	return resp, nil
}

// CloseIdleConnections lets http.Client.CloseIdleConnections reach the pooled transport, as wireScrubTransport does.
func (t adminBodyTransport) CloseIdleConnections() {
	if c, ok := t.base.(interface{ CloseIdleConnections() }); ok {
		c.CloseIdleConnections()
	}
}

// endedBody hands over at most left bytes and then reports the end without asking the body for more. Close closes the body
// — before its end, net/http drops that connection.
type endedBody struct {
	rc   io.ReadCloser
	left int64
}

func (b *endedBody) Read(p []byte) (int, error) {
	if b.left <= 0 {
		return 0, io.EOF
	}
	if int64(len(p)) > b.left {
		p = p[:b.left]
	}
	n, err := b.rc.Read(p)
	b.left -= int64(n)
	return n, err
}

func (b *endedBody) Close() error { return b.rc.Close() }
