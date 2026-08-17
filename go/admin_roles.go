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

// Update replaces the realm role addressed by its CURRENT name; rename by giving
// the new name in role.Name.
//
// ⚠️ name은 **경로**이고 role은 **body**다 — 둘을 합치지 말 것. gocloak의 UpdateRealmRole이
// 경로를 name 인자에서 만들고 body를 그대로 보내므로, `role.Name = &name`을 주입하면
// rename이 조용한 no-op이 된다(.NET·Ruby도 같은 분리를 계약으로 둔다).
func (r *RolesResource) Update(ctx context.Context, name string, role gocloak.Role) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(func() error { return r.a.gc.UpdateRealmRole(ctx, tok, r.a.realm, name, role) })
}

// Delete removes a realm role by name.
func (r *RolesResource) Delete(ctx context.Context, name string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(func() error { return r.a.gc.DeleteRealmRole(ctx, tok, r.a.realm, name) })
}
