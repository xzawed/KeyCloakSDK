package keycloak

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
)

// createdKey marks the context of a facade create. The admin transport keeps, for the 2xx that answers it, the Location
// and the URL the request went to (adminBodyTransport); created reads the id from those, not from gocloak's return value —
// gocloak's getID is the last "/" piece of the raw header, so a relative Location was not resolved, a query or a fragment
// stayed in the id, and another collection's id came back as this one's (registry admin-create-relative-location).
type createdKey int

// createdAnswer is what the transport kept for a facade create's 2xx.
type createdAnswer struct {
	location string // "" when the answer had none
	sentTo   *url.URL
}

// createdSlot holds the last 2xx answer of the marked create.
type createdSlot struct{ answer atomic.Pointer[createdAnswer] }

// keepCreated records resp — a 2xx answering req — in the slot req's context carries, if any.
func keepCreated(req *http.Request, resp *http.Response) {
	if s, _ := req.Context().Value(createdKey(0)).(*createdSlot); s != nil && resp.StatusCode/100 == 2 {
		s.answer.Store(&createdAnswer{location: resp.Header.Get("Location"), sentTo: req.URL})
	}
}

// created runs a facade create through run and returns the id the Location of its 2xx names (createdID). fn gets ctx with
// the create marked and withoutBody — a create reads no success body. "" — no id — is not an error: a create whose answer
// names none returns ("", nil), as one without a Location always did.
func created(ctx context.Context, fn func(context.Context) error) (string, error) {
	s := new(createdSlot)
	ctx = context.WithValue(ctx, createdKey(0), s)
	if err := run(ctx, func(ctx context.Context) error { return fn(withoutBody(ctx)) }); err != nil {
		return "", err
	}
	if a := s.answer.Load(); a != nil {
		return createdID(a.location, a.sentTo), nil
	}
	return "", nil
}

// createdID is the id a create's Location names — the same rule in all nine SDKs: the value, trimmed of SP and HTAB,
// resolved against the URL the create was sent to (RFC 9110 §10.2.2 — a relative one too), then the last segment of the
// resolved path as it came (EscapedPath — not decoded; one trailing "/" ignored), whose segment before it must be the
// collection the create posted to. Never the query or the fragment. "" — no id — when the value is empty or does not
// parse, or the resolved path names no id in that collection (another collection's id included).
func createdID(location string, sentTo *url.URL) string {
	location = strings.Trim(location, " \t")
	if location == "" {
		return ""
	}
	ref, err := url.Parse(location)
	if err != nil {
		return ""
	}
	collection, id, ok := lastSegments(sentTo.ResolveReference(ref).EscapedPath())
	_, posted, _ := lastSegments(sentTo.EscapedPath())
	if !ok || id == "" || collection != posted {
		return ""
	}
	return id
}

// lastSegments is the last two segments of a URL path, one trailing "/" ignored; ok is false when it has one only.
func lastSegments(path string) (before, last string, ok bool) {
	head, last, ok := cutLast(strings.TrimSuffix(path, "/"))
	if !ok {
		return "", last, false
	}
	_, before, _ = cutLast(head)
	return before, last, true
}

// cutLast cuts s around its last "/" — ok is false, and after is all of s, when it has none.
func cutLast(s string) (before, after string, ok bool) {
	i := strings.LastIndexByte(s, '/')
	if i < 0 {
		return "", s, false
	}
	return s[:i], s[i+1:], true
}
