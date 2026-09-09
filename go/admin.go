package keycloak

import (
	"context"
	"errors"
	"net/http"
	"strings"
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
	gc *gocloak.GoCloak
	tr *http.Transport // 보관: Close에서 유휴 keep-alive 커넥션 드레인
	// baseURL: gocloak의 basePath와 **같은 규칙으로** 정규화해 보관한다
	// (`strings.TrimRight(url, "/")`). realms.Update만 raw PUT을 쓰는데, 경로를 만드는
	// gocloak의 getAdminRealmURL이 비공개라 여기서 같은 모양으로 조립해야 하기 때문이다.
	baseURL string
	realm   string
	tp      TokenProvider

	Users   *UsersResource
	Clients *ClientsResource
	Realms  *RealmsResource
	Roles   *RolesResource
	Groups  *GroupsResource
}

// newAdminClient builds the gocloak client, injects the read timeout, and
// authenticates via client-credentials (single-flight cached). clientSecret is
// required; without it the call fails before any network access.
// newAdminTransport builds the hardened gocloak client both construction paths share.
//
// ⚠️ **This must stay the single place that applies the hardening.** The default path and the
// consumer-injected path (NewAdminClient) both go through it — duplicate it and the two paths
// drift, which is exactly how one of them ends up weaker than the other.
func newAdminTransport(cfg Config) (*gocloak.GoCloak, *http.Transport) {
	gc := gocloak.NewClient(cfg.ServerURL)
	// ReadTimeout = overall deadline; ConnectTimeout = dial/TLS-handshake deadline
	// (injected via the transport — previously a silent no-op for admin calls).
	tr := cfg.transport()
	gc.RestyClient().SetTimeout(time.Duration(cfg.ReadTimeout) * time.Millisecond).SetTransport(tr)
	// SSRF hardening for the admin lane. resty owns its own *http.Client, so Config.httpClient()'s
	// CheckRedirect never reached admin requests — including LoginClient, which carries the client
	// secret. ⚠️ This lane uses the **erroring** mode (see config.go): gocloak's error test is
	// resty's IsError() == `StatusCode() > 399`, so a merely *surfaced* 3xx would read as success.
	// ⚠️ Do not call resty's SetRedirectPolicy — it overwrites this assignment.
	gc.RestyClient().GetClient().CheckRedirect = errOnRedirect
	return gc, tr
}

// assembleAdmin wires the resource facades onto a hardened client. Shared by both paths.
func assembleAdmin(gc *gocloak.GoCloak, tr *http.Transport, cfg Config, tp TokenProvider) *AdminClient {
	a := &AdminClient{gc: gc, tr: tr, baseURL: strings.TrimRight(cfg.ServerURL, "/"), realm: cfg.Realm, tp: tp}
	a.Users = &UsersResource{a}
	a.Clients = &ClientsResource{a}
	a.Realms = &RealmsResource{a}
	a.Roles = &RolesResource{a}
	a.Groups = &GroupsResource{a}
	return a
}

// NewAdminClient assembles the admin facade around a caller-supplied TokenProvider.
//
// This is the inlet the TokenProvider godoc promises. Until now `TokenProvider`, `TokenSource` and
// `NewClientCredentialsTokenProvider` were all exported while **no exported function accepted a
// TokenProvider**, so a consumer could build a provider and had nowhere to hand it. The sibling
// SDKs all expose this seam (node `AdminClient.create(config, tokenProvider)`, ruby
// `Admin::AdminClient.new(config:, token_provider:)`, dotnet `AdminClient.CreateAsync(cfg, ITokenProvider)`).
//
// The SDK still owns the HTTP stack: timeouts, transport and the erroring redirect policy come from
// the same helper the default path uses. **Only the token source is replaced.**
//
// ⚠️ clientSecret is NOT required here — replacing client-credentials is the point of injecting.
// ⚠️ Caching and single-flight live on the *provider*, not on AdminClient: a provider that does not
// cache will issue a grant on every admin call. Wrap yours in NewClientCredentialsTokenProvider (or
// cache it yourself) unless you mean that.
func NewAdminClient(ctx context.Context, cfg Config, tp TokenProvider) (*AdminClient, error) {
	if tp == nil {
		return nil, &ConfigError{Msg: "tokenProvider is required"}
	}
	cfg = cfg.withDefaults()
	gc, tr := newAdminTransport(cfg)
	a := assembleAdmin(gc, tr, cfg, tp)
	// Eager authentication — same contract as the default path: a provider that cannot mint a token
	// fails at construction, not at the first admin call.
	if _, err := tp.Token(ctx); err != nil {
		return nil, err
	}
	return a, nil
}

func newAdminClient(ctx context.Context, cfg Config) (*AdminClient, error) {
	if cfg.ClientSecret == "" {
		return nil, &ConfigError{Msg: "clientSecret is required for admin client-credentials"}
	}
	gc, tr := newAdminTransport(cfg)

	tp := NewClientCredentialsTokenProvider(func(ctx context.Context) (*TokenSet, error) {
		jwt, err := gc.LoginClient(ctx, cfg.ClientID, cfg.ClientSecret, cfg.Realm)
		if err != nil {
			return nil, toSDKError(err)
		}
		// gocloak reports a non-2xx it can still unmarshal as success — a 3xx surfaced by
		// noFollowRedirect, or any body without an access_token, yields a zero-value JWT and a
		// nil error. Handing that upward would install an **empty bearer token** on every admin
		// request. Measured: a 302 on the token endpoint returned ("", nil) before this check.
		if jwt == nil || jwt.AccessToken == "" {
			return nil, &AuthError{Msg: "client-credentials login returned no access token"}
		}
		return &TokenSet{AccessToken: jwt.AccessToken, ExpiresIn: int64(jwt.ExpiresIn)}, nil
	}, cfg.ClockSkew)

	a := assembleAdmin(gc, tr, cfg, tp)

	// Eager authentication: fail fast on bad credentials (matches Java/Python/Node).
	if _, err := tp.Token(ctx); err != nil {
		return nil, err
	}
	return a, nil
}

// Raw exposes the underlying gocloak client for endpoints the facade does not wrap.
func (a *AdminClient) Raw() *gocloak.GoCloak { return a.gc }

// Close releases admin resources by draining the idle keep-alive connections held
// by the underlying gocloak/resty transport.
func (a *AdminClient) Close() error {
	a.tr.CloseIdleConnections()
	return nil
}

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
