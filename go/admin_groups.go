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
	return call(ctx, func(ctx context.Context) (string, error) {
		return r.a.gc.CreateGroup(withoutBody(ctx), tok, r.a.realm, group)
	})
}

// Get returns a group by id; ErrNotFound if absent.
func (r *GroupsResource) Get(ctx context.Context, id string) (*gocloak.Group, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(ctx, func(ctx context.Context) (*gocloak.Group, error) { return r.a.gc.GetGroup(ctx, tok, r.a.realm, id) })
}

// List returns top-level groups with pagination.
func (r *GroupsResource) List(ctx context.Context, first, max int) ([]*gocloak.Group, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	params := gocloak.GetGroupsParams{First: &first, Max: &max}
	return call(ctx, func(ctx context.Context) ([]*gocloak.Group, error) {
		return r.a.gc.GetGroups(ctx, tok, r.a.realm, params)
	})
}

// Update replaces the group identified by id (rename by giving the new name in group.Name).
//
// ⚠️ id를 body에 **주입해야 한다** — gocloak의 UpdateGroup은 경로를 body의 .ID에서 만들고,
// 비어 있으면 HTTP 이전에 `errors.Wrap`(= APIError가 아님)으로 죽어 `toSDKError`가 이를
// AdminError가 아니라 TransportError로 오분류한다. users/clients와 같은 모양이다.
func (r *GroupsResource) Update(ctx context.Context, id string, group gocloak.Group) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	group.ID = &id
	return run(ctx, func(ctx context.Context) error { return r.a.gc.UpdateGroup(withoutBody(ctx), tok, r.a.realm, group) })
}

// Delete removes a group by id.
func (r *GroupsResource) Delete(ctx context.Context, id string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(ctx, func(ctx context.Context) error { return r.a.gc.DeleteGroup(withoutBody(ctx), tok, r.a.realm, id) })
}
