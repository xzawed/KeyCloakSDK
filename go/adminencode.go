package keycloak

import (
	"context"
	"encoding/json"
	"reflect"
	"unicode/utf8"
)

// unencodableBody is the message of an admin write whose request body JSON cannot carry faithfully — the same words in
// the nine SDKs (node's UNENCODABLE_BODY).
const unencodableBody = "admin request failed: the request body could not be encoded as JSON"

// writeToken is token for a facade write whose request body is body. The body is judged first (encodableBody), so a
// body JSON cannot carry faithfully is refused before any request — the token request included. It lives here, not in
// the facade files: those are left out of the unit coverage gate, and the integration run never sends such a body.
func (a *AdminClient) writeToken(ctx context.Context, body any) (string, error) {
	if err := encodableBody(body); err != nil {
		return "", err
	}
	return a.token(ctx)
}

// encodableBody refuses, with *TransportError and the common message, an admin write body JSON cannot carry faithfully
// (registry admin-unencodable-body-residuals):
//   - one encoding/json refuses: a NaN or an infinite number anywhere, a cycle, a channel or a func, an invalid
//     json.Number, a failing MarshalJSON. gocloak used to put its own words on that failure ("could not create user:
//     json: unsupported value: NaN"); the cause stays encoding/json's error. resty writes the body with the same
//     json.Marshal, so a body that passes here encodes there. Every error is refused, not only the typed three:
//     json.Number("NaN") fails with a plain error (measured: *errors.errorString);
//   - one with a string that is not valid UTF-8 (faithfulText): encoding/json writes U+FFFD for each invalid byte
//     without an error, so the server would store other text than the caller's.
func encodableBody(body any) error {
	if _, err := json.Marshal(body); err != nil {
		return &TransportError{Msg: unencodableBody, Cause: err}
	}
	if !faithfulText(reflect.ValueOf(body)) {
		return &TransportError{Msg: unencodableBody}
	}
	return nil
}

// faithfulText reports whether every string encoding/json writes from v is valid UTF-8 — a value, a map key, a string
// an interface holds, at any depth. It follows the fields json writes (exported or embedded, not tagged `json:"-"`) and
// does not ask a MarshalJSON or MarshalText: a caller's own type in a free-form field is judged by its strings as well.
// A pointer, map or slice is visited once, so a reference cycle json never walks (one behind a MarshalJSON) still ends.
func faithfulText(root reflect.Value) bool {
	type ref struct {
		t reflect.Type
		p uintptr
		n int
	}
	seen := map[ref]bool{}
	var walk func(v reflect.Value) bool
	walk = func(v reflect.Value) bool {
		switch v.Kind() {
		case reflect.String:
			return utf8.ValidString(v.String())
		case reflect.Interface:
			return v.IsNil() || walk(v.Elem())
		case reflect.Pointer, reflect.Map, reflect.Slice:
			r := ref{t: v.Type(), p: v.Pointer()}
			if v.Kind() == reflect.Slice {
				r.n = v.Len()
			}
			if v.IsNil() || seen[r] {
				return true
			}
			seen[r] = true
		}
		switch v.Kind() {
		case reflect.Pointer:
			return walk(v.Elem())
		case reflect.Map:
			for it := v.MapRange(); it.Next(); {
				if !walk(it.Key()) || !walk(it.Value()) {
					return false
				}
			}
		case reflect.Slice, reflect.Array:
			for i := range v.Len() {
				if !walk(v.Index(i)) {
					return false
				}
			}
		case reflect.Struct:
			for i := range v.NumField() {
				f := v.Type().Field(i)
				if (f.IsExported() || f.Anonymous) && f.Tag.Get("json") != "-" && !walk(v.Field(i)) {
					return false
				}
			}
		}
		return true
	}
	return walk(root)
}
