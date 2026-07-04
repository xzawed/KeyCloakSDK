package keycloak

import (
	"context"

	"github.com/Nerzal/gocloak/v13"
)

// RolesResource manages realm roles. Roles are looked up and deleted by name.
type RolesResource struct{ a *AdminClient }

// Create creates a realm role.
func (r *RolesResource) Create(ctx context.Context, role gocloak.Role) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	_, err = call(func() (string, error) { return r.a.gc.CreateRealmRole(ctx, tok, r.a.realm, role) })
	return err
}

// Get returns a realm role by name; ErrNotFound if absent.
func (r *RolesResource) Get(ctx context.Context, name string) (*gocloak.Role, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(func() (*gocloak.Role, error) { return r.a.gc.GetRealmRole(ctx, tok, r.a.realm, name) })
}

// List returns all realm roles.
func (r *RolesResource) List(ctx context.Context) ([]*gocloak.Role, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(func() ([]*gocloak.Role, error) {
		return r.a.gc.GetRealmRoles(ctx, tok, r.a.realm, gocloak.GetRoleParams{})
	})
}

// Delete removes a realm role by name.
func (r *RolesResource) Delete(ctx context.Context, name string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(func() error { return r.a.gc.DeleteRealmRole(ctx, tok, r.a.realm, name) })
}
