package keycloak

import (
	"context"
	"net/url"

	"github.com/Nerzal/gocloak/v13"
)

// RealmsResource manages realms. It is not realm-scoped: methods take the target
// realm name (Create's representation carries the new realm's name).
type RealmsResource struct{ a *AdminClient }

// Create creates a new realm (representation.Realm is the new realm's name).
func (r *RealmsResource) Create(ctx context.Context, realm gocloak.RealmRepresentation) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	_, err = call(ctx, func(ctx context.Context) (string, error) { return r.a.gc.CreateRealm(withoutBody(ctx), tok, realm) })
	return err
}

// Get returns a realm by name; ErrNotFound if absent.
func (r *RealmsResource) Get(ctx context.Context, realmName string) (*gocloak.RealmRepresentation, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(ctx, func(ctx context.Context) (*gocloak.RealmRepresentation, error) {
		return r.a.gc.GetRealm(ctx, tok, realmName)
	})
}

// List returns every realm the caller can see. A service account normally sees
// only the realms its roles reach — do not assume the full set.
func (r *RealmsResource) List(ctx context.Context) ([]*gocloak.RealmRepresentation, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(ctx, func(ctx context.Context) ([]*gocloak.RealmRepresentation, error) { return r.a.gc.GetRealms(ctx, tok) })
}

// Update replaces the realm addressed by its CURRENT name; rename by giving the
// new name in realm.Realm.
//
// ⚠️ **Of the nine languages, only this method does not go through gocloak.** gocloak's UpdateRealm
// builds the path from the body's `.Realm` (`Put(getAdminRealmURL(PString(realm.Realm)))`), so path
// and body cannot be separated, and therefore **a rename cannot be expressed** — Ruby, .NET and PHP
// all use `PUT /admin/realms/{current name}` + the body as-is, so a rename works. To hold the §4
// isomorphism, this is the only place that uses a raw PUT (the same idiom as .NET filling the gaps in
// its typed client with raw REST).
//
// The error is re-wrapped as `*gocloak.APIError` so that `toSDKError` classifies it **identically** to
// the other methods — it creates no new error class.
func (r *RealmsResource) Update(ctx context.Context, realmName string, realm gocloak.RealmRepresentation) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(ctx, func(ctx context.Context) error {
		resp, err := r.a.gc.GetRequestWithBearerAuth(withoutBody(ctx), tok).
			SetBody(realm).
			Put(r.a.baseURL + "/admin/realms/" + url.PathEscape(realmName))
		if err != nil {
			return &gocloak.APIError{Code: 0, Message: err.Error()}
		}
		// ⚠️ Not resp.IsError() — that is resty's `StatusCode() > 399`, so a 3xx would read as
		// success here. errOnRedirect already refuses redirects at the transport, but this is the
		// one hand-rolled request in the facade: state the 2xx contract explicitly rather than
		// inherit resty's.
		if resp.StatusCode() < 200 || resp.StatusCode() >= 300 {
			return &gocloak.APIError{Code: resp.StatusCode(), Message: string(resp.Body())}
		}
		return nil
	})
}

// Delete removes a realm by name.
func (r *RealmsResource) Delete(ctx context.Context, realmName string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(ctx, func(ctx context.Context) error { return r.a.gc.DeleteRealm(withoutBody(ctx), tok, realmName) })
}
