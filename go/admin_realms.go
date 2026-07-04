package keycloak

import (
	"context"

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
	_, err = call(func() (string, error) { return r.a.gc.CreateRealm(ctx, tok, realm) })
	return err
}

// Get returns a realm by name; ErrNotFound if absent.
func (r *RealmsResource) Get(ctx context.Context, realmName string) (*gocloak.RealmRepresentation, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(func() (*gocloak.RealmRepresentation, error) { return r.a.gc.GetRealm(ctx, tok, realmName) })
}

// Delete removes a realm by name.
func (r *RealmsResource) Delete(ctx context.Context, realmName string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(func() error { return r.a.gc.DeleteRealm(ctx, tok, realmName) })
}
