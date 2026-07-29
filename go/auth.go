package keycloak

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/clientcredentials"
)

// AuthClient is the authentication (OIDC/OAuth2) facade. It wraps
// golang.org/x/oauth2 and converts sub-library errors to *AuthError at the
// boundary. Network boundary: excluded from the coverage gate and exercised by
// httptest unit tests plus the integration suite (Task 10).
//
// TLS is verified by default: Go's http.Client verifies certificates for https
// and transparently allows http for local/test — no insecure opt-out is exposed.
type AuthClient struct {
	cfg    Config
	ep     endpoints
	val    *Validator
	client *http.Client
}

func newAuthClient(cfg Config, v *Validator) *AuthClient {
	return &AuthClient{
		cfg: cfg, ep: oidcEndpoints(cfg), val: v,
		client: cfg.httpClient(),
	}
}

func (a *AuthClient) oauthCtx(ctx context.Context) context.Context {
	return context.WithValue(ctx, oauth2.HTTPClient, a.client)
}

func (a *AuthClient) scope() string {
	if len(a.cfg.Scopes) > 0 {
		return strings.Join(a.cfg.Scopes, " ")
	}
	return "openid"
}

func (a *AuthClient) codeConfig(redirectURI string) *oauth2.Config {
	return &oauth2.Config{
		ClientID:     a.cfg.ClientID,
		ClientSecret: a.cfg.ClientSecret,
		Endpoint: oauth2.Endpoint{
			AuthURL: a.ep.authorization, TokenURL: a.ep.token, AuthStyle: oauth2.AuthStyleInParams,
		},
		RedirectURL: redirectURI,
		Scopes:      a.cfg.Scopes,
	}
}

// CreateAuthorizationRequest builds a PKCE(S256) authorization URL (synchronous,
// no network). The caller stores CodeVerifier/State/Nonce until the callback.
func (a *AuthClient) CreateAuthorizationRequest(redirectURI string) AuthorizationRequest {
	verifier := oauth2.GenerateVerifier()
	state := oauth2.GenerateVerifier()
	nonce := oauth2.GenerateVerifier()
	u := a.codeConfig(redirectURI).AuthCodeURL(state,
		oauth2.S256ChallengeOption(verifier),
		oauth2.SetAuthURLParam("scope", a.scope()),
		oauth2.SetAuthURLParam("nonce", nonce),
	)
	return AuthorizationRequest{URL: u, CodeVerifier: verifier, State: state, Nonce: nonce}
}

// ClientCredentialsToken obtains a service-account token via the
// client_credentials grant.
func (a *AuthClient) ClientCredentialsToken(ctx context.Context) (*TokenSet, error) {
	cc := &clientcredentials.Config{
		ClientID: a.cfg.ClientID, ClientSecret: a.cfg.ClientSecret,
		TokenURL: a.ep.token, Scopes: a.cfg.Scopes, AuthStyle: oauth2.AuthStyleInParams,
	}
	tok, err := cc.Token(a.oauthCtx(ctx))
	if err != nil {
		return nil, &AuthError{Msg: "client credentials grant failed", OAuthError: oauthError(err), Cause: err}
	}
	return tokenSetFromToken(tok), nil
}

// ExchangeCode exchanges an authorization code + PKCE verifier for tokens.
//
// When expectedNonce is non-empty (the nonce returned by
// CreateAuthorizationRequest), the returned id_token is fully signature-
// validated (iss/aud/exp via the hardened Validator — Keycloak id_token aud ==
// clientID, which is what the Validator expects unless Config.ExpectedAudience
// overrides it) and its nonce claim
// is compared against expectedNonce — OIDC nonce replay protection. A mismatch,
// a missing id_token, or a validation failure all fail closed. An empty
// expectedNonce skips id_token validation (custom no-nonce flows).
func (a *AuthClient) ExchangeCode(ctx context.Context, code, redirectURI, codeVerifier, expectedNonce string) (*TokenSet, error) {
	tok, err := a.codeConfig(redirectURI).Exchange(a.oauthCtx(ctx), code, oauth2.VerifierOption(codeVerifier))
	if err != nil {
		return nil, &AuthError{Msg: "authorization code exchange failed", OAuthError: oauthError(err), Cause: err}
	}
	ts := tokenSetFromToken(tok)
	if expectedNonce != "" {
		if err := a.verifyNonce(ctx, ts.IDToken, expectedNonce); err != nil {
			return nil, err
		}
	}
	return ts, nil
}

// verifyNonce validates the id_token and checks its nonce claim against
// expectedNonce. Reuses the access-token Validator (aud == Config.ExpectedAudience,
// i.e. clientID unless overridden).
func (a *AuthClient) verifyNonce(ctx context.Context, idToken, expectedNonce string) error {
	if idToken == "" {
		return &AuthError{Msg: "authorization code exchange failed: missing id_token for nonce validation"}
	}
	vt, err := a.val.Validate(ctx, idToken)
	if err != nil {
		return &AuthError{Msg: "authorization code exchange failed: invalid id_token", Cause: err}
	}
	if n, _ := vt.Claims["nonce"].(string); n != expectedNonce {
		return &AuthError{Msg: "authorization code exchange failed: unexpected nonce"}
	}
	return nil
}

// Refresh obtains a new access token from a refresh token.
func (a *AuthClient) Refresh(ctx context.Context, refreshToken string) (*TokenSet, error) {
	src := a.codeConfig("").TokenSource(a.oauthCtx(ctx), &oauth2.Token{RefreshToken: refreshToken})
	tok, err := src.Token()
	if err != nil {
		return nil, &AuthError{Msg: "token refresh failed", OAuthError: oauthError(err), Cause: err}
	}
	return tokenSetFromToken(tok), nil
}

// Introspect performs RFC 7662 token introspection.
func (a *AuthClient) Introspect(ctx context.Context, token string) (*IntrospectionResult, error) {
	form := url.Values{"token": {token}, "client_id": {a.cfg.ClientID}}
	if a.cfg.ClientSecret != "" {
		form.Set("client_secret", a.cfg.ClientSecret)
	}
	body, err := a.postForm(ctx, a.ep.introspection, form)
	if err != nil {
		return nil, err
	}
	var raw map[string]any
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, &AuthError{Msg: "introspection response parse failed", Cause: err}
	}
	res := &IntrospectionResult{Claims: raw}
	if v, ok := raw["active"].(bool); ok {
		res.Active = v
	}
	if v, ok := raw["username"].(string); ok {
		res.Username = v
	}
	if v, ok := raw["client_id"].(string); ok {
		res.ClientID = v
	}
	return res, nil
}

// Logout invalidates a session via the backchannel logout (refresh-token revoke).
func (a *AuthClient) Logout(ctx context.Context, refreshToken string) error {
	form := url.Values{"refresh_token": {refreshToken}, "client_id": {a.cfg.ClientID}}
	if a.cfg.ClientSecret != "" {
		form.Set("client_secret", a.cfg.ClientSecret)
	}
	_, err := a.postForm(ctx, a.ep.endSession, form)
	return err
}

// Validate verifies an access token's signature and hardened claims.
func (a *AuthClient) Validate(ctx context.Context, accessToken string) (*ValidatedToken, error) {
	return a.val.Validate(ctx, accessToken)
}

// Close releases auth resources by draining the idle keep-alive connections held
// by the auth HTTP client and the JWKS validator's client.
func (a *AuthClient) Close() error {
	// auth 클라이언트와 JWKS 검증기 클라이언트(둘 다 MaxIdleConns=100 커스텀 transport)의 유휴
	// keep-alive 커넥션을 드레인한다. 이전엔 no-op이라 Close 후에도 유휴 소켓/FD가 IdleConnTimeout(90s)
	// 까지 잔류했다(Java/Python 파사드가 close에서 풀을 정리하는 것과 동형).
	a.client.CloseIdleConnections()
	if a.val != nil && a.val.opts.httpClient != nil {
		a.val.opts.httpClient.CloseIdleConnections()
	}
	return nil
}

func (a *AuthClient) postForm(ctx context.Context, endpoint string, form url.Values) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, &TransportError{Msg: err.Error(), Cause: err}
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, &TransportError{Msg: err.Error(), Cause: err}
	}
	defer func() { _ = resp.Body.Close() }()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, &TransportError{Msg: err.Error(), Cause: err}
	}
	if resp.StatusCode >= 400 {
		return nil, &AuthError{Msg: "request to " + endpoint + " failed (HTTP " + strconv.Itoa(resp.StatusCode) + ")"}
	}
	return body, nil
}

func oauthError(err error) string {
	var re *oauth2.RetrieveError
	if errors.As(err, &re) {
		return re.ErrorCode
	}
	return ""
}
