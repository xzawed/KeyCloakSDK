package keycloak

// mask returns a fully opaque placeholder for secrets and tokens, never
// exposing their length or any prefix.
func mask(string) string { return "***" }
