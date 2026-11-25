// The integration suite — #[ignore]: the unit run compiles it and skips it (the lane runs it with --ignored).
use kc_fixture::auth_client::AuthClient;

#[test]
#[ignore]
fn logout_url_names_the_realm() {
    assert_eq!(AuthClient::new("kc").logout_url(), "/realms/kc/logout");
}
