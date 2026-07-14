package keycloak

import (
	"context"
	"errors"
	"time"

	"github.com/Nerzal/gocloak/v13"
)

// AdminClient is the Admin REST API facade. It wraps github.com/Nerzal/gocloak/v13
// and converts *gocloak.APIError to the SDK error taxonomy at the boundary.
// Resource representation types (gocloak.User, Client, ...) are exposed as the
// data model — a documented hiding-exception, matching the Java/Node admin facade.
//
// Network boundary: excluded from the coverage gate and verified by the
// integration suite (Task 10).
type AdminClient struct {
	gc    *gocloak.GoCloak
	realm string
	tp    TokenProvider

	Users   *UsersResource
	Clients *ClientsResource
	Realms  *RealmsResource
	Roles   *RolesResource
	Groups  *GroupsResource
}

// newAdminClient builds the gocloak client, injects the read timeout, and
// authenticates via client-credentials (single-flight cached). clientSecret is
// required; without it the call fails before any network access.
func newAdminClient(ctx context.Context, cfg Config) (*AdminClient, error) {
	if cfg.ClientSecret == "" {
		return nil, &ConfigError{Msg: "clientSecret is required for admin client-credentials"}
	}
	gc := gocloak.NewClient(cfg.ServerURL)
	// ReadTimeout = overall deadline; ConnectTimeout = dial/TLS-handshake deadline
	// (injected via the transport — previously a silent no-op for admin calls).
	gc.RestyClient().SetTimeout(time.Duration(cfg.ReadTimeout) * time.Millisecond).SetTransport(cfg.transport())

	tp := NewClientCredentialsTokenProvider(func(ctx context.Context) (*TokenSet, error) {
		jwt, err := gc.LoginClient(ctx, cfg.ClientID, cfg.ClientSecret, cfg.Realm)
		if err != nil {
			return nil, toSDKError(err)
		}
		return &TokenSet{AccessToken: jwt.AccessToken, ExpiresIn: int64(jwt.ExpiresIn)}, nil
	}, cfg.ClockSkew)

	a := &AdminClient{gc: gc, realm: cfg.Realm, tp: tp}
	a.Users = &UsersResource{a}
	a.Clients = &ClientsResource{a}
	a.Realms = &RealmsResource{a}
	a.Roles = &RolesResource{a}
	a.Groups = &GroupsResource{a}

	// Eager authentication: fail fast on bad credentials (matches Java/Python/Node).
	if _, err := tp.Token(ctx); err != nil {
		return nil, err
	}
	return a, nil
}

// Raw exposes the underlying gocloak client for endpoints the facade does not wrap.
func (a *AdminClient) Raw() *gocloak.GoCloak { return a.gc }

// Close releases admin resources (currently a no-op; kept for lifecycle symmetry).
func (a *AdminClient) Close() error { return nil }

func (a *AdminClient) token(ctx context.Context) (string, error) { return a.tp.Token(ctx) }

// call runs a gocloak call and converts its error to the SDK taxonomy.
func call[T any](fn func() (T, error)) (T, error) {
	v, err := fn()
	if err != nil {
		return v, toSDKError(err)
	}
	return v, nil
}

// run is call for gocloak calls that return only an error.
func run(fn func() error) error {
	_, err := call(func() (struct{}, error) { return struct{}{}, fn() })
	return err
}

// toSDKError converts a gocloak error to the SDK taxonomy. gocloak wraps every
// failure — including network/transport failures — into *gocloak.APIError, using
// Code 0 when there was no HTTP response. So an APIError with a real HTTP status
// (>0) becomes *AdminError (matching the sentinels via Is), while a Code-0 error
// or any non-APIError becomes *TransportError (matching Java/Python/Node, where
// network failures map to a transport-level error).
func toSDKError(err error) error {
	var apiErr *gocloak.APIError
	if errors.As(err, &apiErr) && apiErr.Code != 0 {
		return &AdminError{StatusCode: apiErr.Code, Msg: apiErr.Message, Cause: err}
	}
	return &TransportError{Msg: err.Error(), Cause: err}
}
