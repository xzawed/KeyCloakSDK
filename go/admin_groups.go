package keycloak

import (
	"context"

	"github.com/Nerzal/gocloak/v13"
)

// GroupsResource manages groups.
type GroupsResource struct{ a *AdminClient }

// Create creates a group and returns its new id.
func (r *GroupsResource) Create(ctx context.Context, group gocloak.Group) (string, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return "", err
	}
	return call(func() (string, error) { return r.a.gc.CreateGroup(ctx, tok, r.a.realm, group) })
}

// Get returns a group by id; ErrNotFound if absent.
func (r *GroupsResource) Get(ctx context.Context, id string) (*gocloak.Group, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(func() (*gocloak.Group, error) { return r.a.gc.GetGroup(ctx, tok, r.a.realm, id) })
}

// List returns top-level groups with pagination.
func (r *GroupsResource) List(ctx context.Context, first, max int) ([]*gocloak.Group, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	params := gocloak.GetGroupsParams{First: &first, Max: &max}
	return call(func() ([]*gocloak.Group, error) { return r.a.gc.GetGroups(ctx, tok, r.a.realm, params) })
}

// Delete removes a group by id.
func (r *GroupsResource) Delete(ctx context.Context, id string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(func() error { return r.a.gc.DeleteGroup(ctx, tok, r.a.realm, id) })
}
