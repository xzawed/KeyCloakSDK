package fixture

import "fmt"

// AdminClient is the admin facade.
type AdminClient struct{ realm string }

// String is a one-liner whose string literal holds an unmatched brace — a brace counter that did
// not skip literals would read the line as unbalanced and run on into the next function.
func (a AdminClient) String() string { return "AdminClient{" + a.realm }

// NewAdminClient spans several lines and has a branch the run skips.
func NewAdminClient(realm string) (*AdminClient, error) {
	if realm == "" {
		return nil, fmt.Errorf("realm is required")
	}
	return &AdminClient{realm: realm}, nil
}

// Banner holds a raw string with a lone "}" at column 0 — a brace counter that did not skip
// literals would end this function there and lose the blocks after it.
func (a *AdminClient) Banner() string {
	s := `{
}
`
	if a.realm == "" {
		return s
	}
	return s + a.realm
}

// Close is never called by the fixture run.
func (a *AdminClient) Close() error {
	a.realm = ""
	return nil
}
