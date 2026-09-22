//! 공개 표면에 나타나는 foreign 타입이 **크레이트 루트만으로 이름 붙는가**.
//!
//! ⚠️ 이 파일은 단언보다 **컴파일 자체가 시험**이다. `keycloak_sdk` 하나만 의존하는 소비자를
//! 흉내 내므로, 루트 재노출이 빠지면 컴파일되지 않는다(변이 실측 2026-09-22: `Jwk` 재노출을
//! 지우면 `error[E0432]: unresolved import keycloak_sdk::Jwk`).
//!
//! `.claude/rules/rust.md` §4(b) 의 「foreign 타입이 새 공개 시그니처에 들어오면 재노출을
//! 늘려라」를 집행하는 자리다 — 그 불변식은 산문으로만 있었고 실제로 두 자리에서 깨져
//! 있었다(`jsonwebtoken::jwk::Jwk` · `keycloak::KeycloakError`).
//!
//! ⚠️ 새 foreign 타입이 공개 시그니처에 들어오면 **여기에 한 줄 추가하고 아래 수를 올린다**.
//! 추가하지 않으면 이 파일은 계속 통과하므로, 이것은 탐지기가 아니라 **회귀 방지**다.

use keycloak_sdk::{
    Jwk, KeycloakAdmin, RawKeycloakError, SdkTokenSupplier,
    types::{
        ClientRepresentation, GroupRepresentation, RealmRepresentation, RoleRepresentation,
        UserRepresentation,
    },
};

#[test]
fn reexports_cover_the_public_surface() {
    // `type_name::<T>()` 은 T 를 **이름 붙일 수 있어야** 컴파일된다 — 값이 필요 없다.
    let named = [
        // admin 파사드가 데이터 모델로 노출하는 representation 5종
        std::any::type_name::<ClientRepresentation>(),
        std::any::type_name::<GroupRepresentation>(),
        std::any::type_name::<RealmRepresentation>(),
        std::any::type_name::<RoleRepresentation>(),
        std::any::type_name::<UserRepresentation>(),
        // `AdminClient::raw()` 의 반환 타입과 그 메서드들이 돌려주는 오류
        std::any::type_name::<KeycloakAdmin<SdkTokenSupplier>>(),
        std::any::type_name::<RawKeycloakError>(),
        // `JwksStore::get_key()` 가 돌려주는 JWK
        std::any::type_name::<Jwk>(),
        // 저수준 주입 생성자 넷이 받는 공유 HTTP 클라이언트
        std::any::type_name::<keycloak_sdk::reqwest::Client>(),
    ];
    assert_eq!(
        named.len(),
        9,
        "공개 표면의 foreign 타입 수가 바뀌었다 — 재노출과 이 목록을 함께 옮길 것(§4(b))"
    );
    assert!(
        named.iter().all(|n| !n.is_empty()),
        "type_name 이 빈 문자열을 냈다 — 이 시험이 공허해졌다"
    );
}
