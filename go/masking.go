package keycloak

import "fmt"

// mask returns a fully opaque placeholder for secrets and tokens, never
// exposing their length or any prefix.
func mask(string) string { return "***" }

// formatMasked is the body of every secret-holding type's fmt.Formatter. fmt asks a Formatter
// **before** String/GoString, for every verb but %T and %p — and without one a non-string verb
// (%d %b %e %t %U …) skips String() and prints the fields by reflection (measured 2026-11-17: seven
// types, value and pointer, 236 renderings in the facade dump). s is the type's masked String().
//
// The string verbs keep what they printed through Stringer/GoStringer, flags and width included:
// %v %+v %s %q %x %X format s, and %#v prints GoString() (which is s) unquoted. Any other verb gets
// fmt's own wrong-verb shape around the masked text: `%!d(keycloak.Config=Config{…})`.
//
// ⚠️ %p never reaches a Formatter: fmt handles it first, and on a value it prints the fields with
// methods turned off. No method can stop that — go vet's printf check flags such a call.
func formatMasked(f fmt.State, verb rune, v any, s string) {
	switch verb {
	case 'v':
		if f.Flag('#') {
			_, _ = fmt.Fprintf(f, fmt.FormatString(f, 's'), s)
			return
		}
		_, _ = fmt.Fprintf(f, fmt.FormatString(f, verb), s)
	case 's', 'q', 'x', 'X':
		_, _ = fmt.Fprintf(f, fmt.FormatString(f, verb), s)
	default:
		_, _ = fmt.Fprintf(f, "%%!%c(%T=%s)", verb, v, s)
	}
}
