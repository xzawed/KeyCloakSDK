package fixture

// AuthClient has a value-receiver Stringer.
type AuthClient struct{ id string }

func (a AuthClient) String() string { return "AuthClient{" + a.id + "}" }

// hook is a package-level function literal — its statements belong to no function declaration.
var hook = func() int {
	return 1
}

// Token runs.
func (a *AuthClient) Token() string {
	if a.id == "" {
		return "anon"
	}
	return "tok-" + a.id
}
