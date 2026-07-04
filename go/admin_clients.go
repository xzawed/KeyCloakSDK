package keycloak

import (
	"context"

	"github.com/Nerzal/gocloak/v13"
)

// ClientsResource manages clients. `id` is the internal UUID; `clientId` is the
// human-assigned identifier.
type ClientsResource struct{ a *AdminClient }

// Create creates a client and returns its internal id (UUID).
func (r *ClientsResource) Create(ctx context.Context, client gocloak.Client) (string, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return "", err
	}
	return call(func() (string, error) { return r.a.gc.CreateClient(ctx, tok, r.a.realm, client) })
}

// Get returns a client by internal id (UUID); ErrNotFound if absent.
func (r *ClientsResource) Get(ctx context.Context, id string) (*gocloak.Client, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(func() (*gocloak.Client, error) { return r.a.gc.GetClient(ctx, tok, r.a.realm, id) })
}

// FindByClientID finds clients by the human-assigned clientId (0..N).
func (r *ClientsResource) FindByClientID(ctx context.Context, clientID string) ([]*gocloak.Client, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	params := gocloak.GetClientsParams{ClientID: &clientID}
	return call(func() ([]*gocloak.Client, error) { return r.a.gc.GetClients(ctx, tok, r.a.realm, params) })
}

// Update updates the client identified by internal id.
func (r *ClientsResource) Update(ctx context.Context, id string, client gocloak.Client) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	client.ID = &id
	return run(func() error { return r.a.gc.UpdateClient(ctx, tok, r.a.realm, client) })
}

// Delete removes a client by internal id.
func (r *ClientsResource) Delete(ctx context.Context, id string) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(func() error { return r.a.gc.DeleteClient(ctx, tok, r.a.realm, id) })
}
