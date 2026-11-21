package fixture

import (
	"errors"
	"strings"
)

// AuthClient is the boundary facade of the fixture.
type AuthClient struct{ realm string }

// Realm is a one-line method the drive calls — fully reached, not listed.
func (a *AuthClient) Realm() string { return a.realm }

// Exchange has its own failure arm the drive never takes (it never sends an empty code).
func (a *AuthClient) Exchange(code string) (string, error) {
	if code == "" {
		return "", errors.New("code is required")
	}
	return "tok-" + code, nil
}

// Pick's miss sits in a function literal — the literal's blocks are Pick's (the drive always finds a match).
func (a *AuthClient) Pick(xs []string) string {
	find := func(prefix string) string {
		for _, x := range xs {
			if strings.HasPrefix(x, prefix) {
				return x
			}
		}
		return ""
	}
	return find("k")
}

// Valid's failure side is an operand of && — not a block of its own, so a run that only passes looks complete.
func (a *AuthClient) Valid(s string) bool {
	return s != "" && strings.HasPrefix(s, "k")
}

// String is a one-line method with a value receiver the drive never calls.
func (a AuthClient) String() string { return "AuthClient{" + a.realm + "}" }

// LogoutURL is called only by the integration test (build tag integration) — outside the unit run.
func (a *AuthClient) LogoutURL() string {
	u := "https://idp.example/realms/" + a.realm
	return u + "/logout"
}

// hook is a package-level function literal — its statements belong to no function declaration.
var hook = func() int {
	return 1
}
