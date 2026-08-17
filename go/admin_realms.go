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

// List returns every realm the caller can see. A service account normally sees
// only the realms its roles reach — do not assume the full set.
func (r *RealmsResource) List(ctx context.Context) ([]*gocloak.RealmRepresentation, error) {
	tok, err := r.a.token(ctx)
	if err != nil {
		return nil, err
	}
	return call(func() ([]*gocloak.RealmRepresentation, error) { return r.a.gc.GetRealms(ctx, tok) })
}

// Update replaces the realm addressed by its CURRENT name; rename by giving the
// new name in realm.Realm.
//
// ⚠️ **아홉 언어 중 이 메서드만 gocloak을 거치지 않는다.** gocloak의 UpdateRealm은 경로를
// body의 `.Realm`에서 만들기 때문에(`Put(getAdminRealmURL(PString(realm.Realm)))`) 경로와
// body를 분리할 수 없고, 그래서 **rename을 표현할 수 없다** — Ruby·.NET·PHP는 전부
// `PUT /admin/realms/{현재이름}` + body 그대로라 rename이 된다. §4 동형을 지키려고 여기만
// raw PUT을 쓴다(.NET이 타입드 클라이언트의 빈칸을 raw REST로 메우는 것과 같은 관용).
//
// 오류는 `*gocloak.APIError`로 되싸서 `toSDKError`가 다른 메서드와 **동일하게** 분류하게 한다
// — 새 오류 계급을 만들지 않는다.
func (r *RealmsResource) Update(ctx context.Context, realmName string, realm gocloak.RealmRepresentation) error {
	tok, err := r.a.token(ctx)
	if err != nil {
		return err
	}
	return run(func() error {
		resp, err := r.a.gc.GetRequestWithBearerAuth(ctx, tok).
			SetBody(realm).
			Put(r.a.baseURL + "/admin/realms/" + url.PathEscape(realmName))
		if err != nil {
			return &gocloak.APIError{Code: 0, Message: err.Error()}
		}
		if resp.IsError() {
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
	return run(func() error { return r.a.gc.DeleteRealm(ctx, tok, realmName) })
}
