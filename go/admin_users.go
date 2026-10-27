package keycloak

import (
	"context"

	"github.com/Nerzal/gocloak/v13"
)

// UsersResource manages users. Model type: gocloak.User (documented hiding-exception).
type UsersResource struct{ a *AdminClient }

// Create creates a user and returns its new id.
func (r *UsersResource) Create(ctx context.Context, user gocloak.User) (string, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return "", err
	}
	return call(ctx, func(ctx context.Context) (string, error) {
		return r.a.gc.CreateUser(withoutBody(ctx), tok, r.a.realm, user)
	})
}

// Get returns a user by id (ErrNotFound if absent).
func (r *UsersResource) Get(ctx context.Context, id string) (*gocloak.User, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(ctx, func(ctx context.Context) (*gocloak.User, error) { return r.a.gc.GetUserByID(ctx, tok, r.a.realm, id) })
}

// Search finds users by username (optional), with pagination.
func (r *UsersResource) Search(ctx context.Context, username string, first, max int) ([]*gocloak.User, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	params := gocloak.GetUsersParams{First: &first, Max: &max}
	if username != "" {
		params.Username = &username
	}
	return call(ctx, func(ctx context.Context) ([]*gocloak.User, error) {
		return r.a.gc.GetUsers(ctx, tok, r.a.realm, params)
	})
}

// Update updates the user identified by id.
func (r *UsersResource) Update(ctx context.Context, id string, user gocloak.User) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	user.ID = &id
	return run(ctx, func(ctx context.Context) error { return r.a.gc.UpdateUser(withoutBody(ctx), tok, r.a.realm, user) })
}

// Delete removes a user by id.
func (r *UsersResource) Delete(ctx context.Context, id string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(ctx, func(ctx context.Context) error { return r.a.gc.DeleteUser(withoutBody(ctx), tok, r.a.realm, id) })
}
