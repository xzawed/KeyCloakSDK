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
	_, err = call(ctx, func(ctx context.Context) (string, error) {
		return r.a.gc.CreateRealmRole(withoutBody(ctx), tok, r.a.realm, role)
	})
	return err
}

// Get returns a realm role by name; ErrNotFound if absent.
func (r *RolesResource) Get(ctx context.Context, name string) (*gocloak.Role, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(ctx, func(ctx context.Context) (*gocloak.Role, error) {
		return r.a.gc.GetRealmRole(ctx, tok, r.a.realm, name)
	})
}

// List returns all realm roles.
func (r *RolesResource) List(ctx context.Context) ([]*gocloak.Role, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(ctx, func(ctx context.Context) ([]*gocloak.Role, error) {
		return r.a.gc.GetRealmRoles(ctx, tok, r.a.realm, gocloak.GetRoleParams{})
	})
}

// Update replaces the realm role addressed by its CURRENT name; rename by giving
// the new name in role.Name.
//
// ⚠️ name is the **path** and role is the **body** — do not merge the two. gocloak's UpdateRealmRole
// builds the path from the name argument and sends the body as-is, so injecting `role.Name = &name`
// turns the rename into a silent no-op (.NET and Ruby also hold the same separation as a contract).
func (r *RolesResource) Update(ctx context.Context, name string, role gocloak.Role) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(ctx, func(ctx context.Context) error {
		return r.a.gc.UpdateRealmRole(withoutBody(ctx), tok, r.a.realm, name, role)
	})
}

// Delete removes a realm role by name.
func (r *RolesResource) Delete(ctx context.Context, name string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(ctx, func(ctx context.Context) error { return r.a.gc.DeleteRealmRole(withoutBody(ctx), tok, r.a.realm, name) })
}
