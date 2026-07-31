//! 자체강화 JWT 검증: RS256 핀(헤더 alg 미신뢰)·none 구조적 거부·iss 정확·aud 포함·exp 필수·nbf·스큐·DoS-safe JWKS.
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::jwks::JwksStore;
use crate::oidc::OidcEndpoints;
use crate::tokens::ValidatedToken;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};

// aud(string 또는 array) → Vec<String>. jsonwebtoken이 aud 포함검사를 하지만 ValidatedToken 매핑용으로 벡터화.
fn aud_to_vec(v: Option<&serde_json::Value>) -> Vec<String> {
    match v {
        Some(serde_json::Value::String(s)) => vec![s.clone()],
        Some(serde_json::Value::Array(a)) => a
            .iter()
            .filter_map(|x| x.as_str().map(String::from))
            .collect(),
        _ => vec![],
    }
}

pub struct JwtValidator {
    issuer: String,
    audience: String,
    clock_skew: u64,
    algorithms: Vec<Algorithm>,
    jwks: JwksStore,
}

impl JwtValidator {
    /// config의 서명 알고리즘 이름을 jsonwebtoken `Algorithm`으로 파싱해 핀을 구성한다.
    /// 빈 집합(alg 핀 무력화)이나 미지원 알고리즘 이름은 `KeycloakError::Config`로 거부한다.
    pub fn new(
        config: &KeycloakConfig,
        endpoints: &OidcEndpoints,
        jwks: JwksStore,
    ) -> Result<Self> {
        if config.signature_algorithms.is_empty() {
            return Err(KeycloakError::Config(
                "signature_algorithms must be non-empty".into(),
            ));
        }
        let mut algorithms = Vec::with_capacity(config.signature_algorithms.len());
        for name in &config.signature_algorithms {
            let alg = name.parse::<Algorithm>().map_err(|_| {
                KeycloakError::Config(format!("unsupported signature algorithm: {name}"))
            })?;
            algorithms.push(alg);
        }
        Ok(Self {
            issuer: endpoints.issuer(),
            // expected_audience가 설정되면 그 값을, 아니면 client_id를 기대한다(기존 동작).
            audience: config
                .expected_audience
                .clone()
                .unwrap_or_else(|| config.client_id.clone()),
            clock_skew: config.clock_skew,
            algorithms,
            jwks,
        })
    }

    pub async fn validate(&self, token: &str) -> Result<ValidatedToken> {
        // (1) 헤더에서 kid만 추출(alg는 검증 선택에 미사용 — RS256 고정 핀).
        //     Algorithm enum에는 `none` 변형이 없어 alg="none" 헤더는 여기서 구조적으로 거부된다.
        let header = jsonwebtoken::decode_header(token)
            .map_err(|_| KeycloakError::TokenValidation("malformed JWT header".into()))?;
        let kid = header
            .kid
            .as_deref()
            .ok_or_else(|| KeycloakError::TokenValidation("missing kid".into()))?;

        // (2) JWKS에서 kid로 키 → DecodingKey (미해결 kid만 DoS-safe 재조회).
        let jwk = self.jwks.get_key(kid).await?;
        let key = DecodingKey::from_jwk(&jwk)
            .map_err(|_| KeycloakError::TokenValidation("invalid JWKS key".into()))?;

        // (3) 강화 Validation: config 알고리즘 핀·iss 정확·aud 포함·exp 필수·nbf·스큐.
        let mut v = Validation::new(self.algorithms[0]); // non-empty 보장(new에서 검증)
        v.algorithms = self.algorithms.clone(); // 헤더 alg 무시하고 설정된 집합만 허용(confusion·none 차단)
        v.set_issuer(&[self.issuer.as_str()]); // 정확 일치(부분/접두/후행슬래시 변형 거부)
        v.set_audience(&[self.audience.as_str()]); // 집합 정확 포함(부분문자열 아님)
        v.validate_exp = true; // exp 검증
        v.validate_nbf = true; // 기본 false → 강화(미래 nbf 거부)
        v.leeway = self.clock_skew; // 기본 60 → config(30)
        v.set_required_spec_claims(&["exp", "iss", "aud"]); // exp/iss/aud 부재 시 거부

        // 전체 클레임을 serde_json::Value로 역직렬화한다(자매 SDK의 claims 맵과 동형 — nonce 등
        // 표준 외 클레임 접근용). 서명·exp·aud·iss·nbf 검증은 T와 무관하게 jsonwebtoken이 수행한다.
        let data = jsonwebtoken::decode::<serde_json::Value>(token, &key, &v).map_err(|e| {
            KeycloakError::TokenValidation(format!("token verification failed: {}", e.kind_str()))
        })?;

        let claims: std::collections::BTreeMap<String, serde_json::Value> = match data.claims {
            serde_json::Value::Object(m) => m.into_iter().collect(),
            _ => std::collections::BTreeMap::new(),
        };
        let str_claim = |k: &str| claims.get(k).and_then(|x| x.as_str()).map(String::from);
        Ok(ValidatedToken {
            subject: str_claim("sub").unwrap_or_default(),
            audience: aud_to_vec(claims.get("aud")),
            issuer: str_claim("iss").unwrap_or_default(),
            expires_at: claims.get("exp").and_then(serde_json::Value::as_u64),
            issued_at: claims.get("iat").and_then(serde_json::Value::as_u64),
            claims,
        })
    }
}

// jsonwebtoken ErrorKind → 짧은 메시지(원문 노출 최소화). ErrorKind는 #[non_exhaustive].
trait KindStr {
    fn kind_str(&self) -> &'static str;
}
impl KindStr for jsonwebtoken::errors::Error {
    fn kind_str(&self) -> &'static str {
        use jsonwebtoken::errors::ErrorKind as K;
        match self.kind() {
            K::ExpiredSignature => "expired",
            K::ImmatureSignature => "not yet valid (nbf)",
            K::InvalidSignature => "invalid signature",
            K::InvalidIssuer => "issuer mismatch",
            K::InvalidAudience => "audience mismatch",
            K::MissingRequiredClaim(_) => "missing required claim",
            K::InvalidAlgorithm | K::InvalidAlgorithmName | K::MissingAlgorithm => {
                "algorithm not allowed"
            }
            _ => "invalid token",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::KeycloakConfig;
    use base64::Engine;
    use jsonwebtoken::{EncodingKey, Header, encode};
    use rsa::pkcs1::EncodeRsaPrivateKey;
    use rsa::pkcs8::EncodePublicKey;
    use rsa::traits::PublicKeyParts;
    use rsa::{RsaPrivateKey, RsaPublicKey};
    use serde_json::json;
    use std::time::{SystemTime, UNIX_EPOCH};
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn now() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
    }
    fn b64(b: &[u8]) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b)
    }

    struct Fixture {
        priv_pem: String,
        pub_pem: String, // SPKI PEM — alg-confusion 프로브의 HMAC "비밀"로 사용(공개키 텍스트)
        jwk: serde_json::Value,
    }

    fn make_key() -> Fixture {
        let mut rng = rand::thread_rng();
        let sk = RsaPrivateKey::new(&mut rng, 2048).unwrap();
        let pk = RsaPublicKey::from(&sk);
        let n = b64(&pk.n().to_bytes_be());
        let e = b64(&pk.e().to_bytes_be());
        let priv_pem = sk
            .to_pkcs1_pem(rsa::pkcs1::LineEnding::LF)
            .unwrap()
            .to_string();
        let pub_pem = pk.to_public_key_pem(rsa::pkcs8::LineEnding::LF).unwrap();
        let jwk = json!({ "kty":"RSA","kid":"test-kid","use":"sig","alg":"RS256","n":n,"e":e });
        Fixture {
            priv_pem,
            pub_pem,
            jwk,
        }
    }

    async fn validator_for(fx: &Fixture) -> JwtValidator {
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client").unwrap();
        validator_for_config(fx, cfg).await
    }

    /// `validator_for`의 config 주입 변형 — expected_audience 등 config 배선을 검증할 때 쓴다.
    async fn validator_for_config(fx: &Fixture, cfg: KeycloakConfig) -> JwtValidator {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"keys":[fx.jwk]})))
            .mount(&server)
            .await;
        // server 수명: MockServer는 drop되면 종료되므로, validator의 JWKS fetch가 성립하도록
        // Box::leak로 유지(테스트 전용 — 실제 코드 아님).
        let endpoints = OidcEndpoints::new(&cfg);
        let jwks_uri = format!("{}/certs", Box::leak(Box::new(server)).uri());
        let store = JwksStore::new(jwks_uri, reqwest::Client::new(), 60);
        JwtValidator::new(&cfg, &endpoints, store).unwrap()
    }

    /// `validator_for`의 변형 — 정상 JWK 대신 호출자가 지정한(악의적/기형) JWKS 바디를
    /// `/certs`가 그대로 반환하도록 mount한다. 악성 JWKS 프로브 전용.
    async fn validator_with_raw_jwks(jwks_body: serde_json::Value) -> JwtValidator {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_body))
            .mount(&server)
            .await;
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client").unwrap();
        let endpoints = OidcEndpoints::new(&cfg);
        let jwks_uri = format!("{}/certs", Box::leak(Box::new(server)).uri());
        let store = JwksStore::new(jwks_uri, reqwest::Client::new(), 60);
        JwtValidator::new(&cfg, &endpoints, store).unwrap()
    }

    fn sign(fx: &Fixture, claims: serde_json::Value, kid: &str) -> String {
        let mut h = Header::new(Algorithm::RS256);
        h.kid = Some(kid.into());
        let ek = EncodingKey::from_rsa_pem(fx.priv_pem.as_bytes()).unwrap();
        encode(&h, &claims, &ek).unwrap()
    }

    fn good_claims() -> serde_json::Value {
        json!({ "sub":"s1", "iss":"http://kc:8080/realms/it-realm",
                "aud":["it-client","account"], "exp": now()+300, "iat": now() })
    }

    // config.signature_algorithms가 검증기 alg 핀으로 배선되는지(하드코딩 RS256 제거) — 빈/미지원 거부.
    #[tokio::test]
    async fn new_rejects_empty_signature_algorithms() {
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client")
            .unwrap()
            .with_signature_algorithms(vec![]);
        let endpoints = OidcEndpoints::new(&cfg);
        let store = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        assert!(matches!(
            JwtValidator::new(&cfg, &endpoints, store),
            Err(KeycloakError::Config(_))
        ));
    }

    #[tokio::test]
    async fn new_rejects_unsupported_algorithm_name() {
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client")
            .unwrap()
            .with_signature_algorithms(vec!["NOPE999".to_string()]);
        let endpoints = OidcEndpoints::new(&cfg);
        let store = JwksStore::new(endpoints.jwks(), reqwest::Client::new(), 60);
        assert!(matches!(
            JwtValidator::new(&cfg, &endpoints, store),
            Err(KeycloakError::Config(_))
        ));
    }

    // ── 브리프 7개: 정상 통과 + 핵심 강화 불변식 거부 ──────────────────────────────

    #[tokio::test]
    async fn valid_token_passes() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let vt = v
            .validate(&sign(&fx, good_claims(), "test-kid"))
            .await
            .unwrap();
        assert_eq!(vt.subject, "s1");
        assert!(vt.audience.contains(&"it-client".to_string()));
        assert_eq!(vt.issuer, "http://kc:8080/realms/it-realm");
    }

    #[tokio::test]
    async fn rejects_wrong_issuer() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims();
        c["iss"] = json!("http://evil/realms/it-realm");
        assert!(matches!(
            v.validate(&sign(&fx, c, "test-kid")).await,
            Err(KeycloakError::TokenValidation(_))
        ));
    }

    #[tokio::test]
    async fn rejects_aud_not_containing_client() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims();
        c["aud"] = json!(["other-client"]);
        assert!(matches!(
            v.validate(&sign(&fx, c, "test-kid")).await,
            Err(KeycloakError::TokenValidation(_))
        ));
    }

    /// expected_audience 미설정(기본): 기대 aud는 client_id — 기존 동작 그대로.
    #[tokio::test]
    async fn expected_audience_unset_falls_back_to_client_id() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        // aud에 client_id가 있으면 통과.
        assert!(
            v.validate(&sign(&fx, good_claims(), "test-kid"))
                .await
                .is_ok()
        );
        // 없으면 여전히 거부.
        let mut c = good_claims();
        c["aud"] = json!(["api://orders"]);
        assert!(matches!(
            v.validate(&sign(&fx, c, "test-kid")).await,
            Err(KeycloakError::TokenValidation(_))
        ));
    }

    /// expected_audience 설정: 기대 aud가 client_id를 *대체*한다(리소스 서버 케이스 —
    /// aud가 요청 클라이언트가 아니라 API 이름인 토큰).
    #[tokio::test]
    async fn expected_audience_overrides_client_id() {
        let fx = make_key();
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client")
            .unwrap()
            .with_expected_audience("api://orders");
        let v = validator_for_config(&fx, cfg).await;
        let mut c = good_claims();
        c["aud"] = json!(["api://orders", "account"]);
        assert!(v.validate(&sign(&fx, c, "test-kid")).await.is_ok());
        // client_id만 담은 토큰은 거부 — 추가가 아니라 대체임을 증명.
        assert!(matches!(
            v.validate(&sign(&fx, good_claims(), "test-kid")).await,
            Err(KeycloakError::TokenValidation(_))
        ));
    }

    #[tokio::test]
    async fn rejects_expired() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims();
        c["exp"] = json!(now() - 100);
        assert!(matches!(
            v.validate(&sign(&fx, c, "test-kid")).await,
            Err(KeycloakError::TokenValidation(_))
        ));
    }

    #[tokio::test]
    async fn rejects_missing_exp() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims();
        c.as_object_mut().unwrap().remove("exp");
        assert!(matches!(
            v.validate(&sign(&fx, c, "test-kid")).await,
            Err(KeycloakError::TokenValidation(_))
        ));
    }

    #[tokio::test]
    async fn rejects_unknown_kid() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        assert!(matches!(
            v.validate(&sign(&fx, good_claims(), "other-kid")).await,
            Err(KeycloakError::TokenValidation(_))
        ));
    }

    #[tokio::test]
    async fn rejects_tampered_signature() {
        let fx = make_key();
        let other = make_key(); // 다른 키로 서명 → JWKS의 키로 검증 실패
        let v = validator_for(&fx).await;
        let tampered = sign(&other, good_claims(), "test-kid");
        assert!(matches!(
            v.validate(&tampered).await,
            Err(KeycloakError::TokenValidation(_))
        ));
    }

    // ── 보안 프로브 5개: 실제 공격 토큰을 구성해 거부를 증명(보안리뷰 선반영) ──────────

    /// RS256→HS256 알고리즘 혼동 공격: 서버 공개키(PEM 텍스트)를 HMAC 비밀로 삼아
    /// HS256으로 유효 서명한 토큰. RS256 핀(v.algorithms=[RS256])이 서명검증 이전에
    /// 헤더 alg를 거부해야 한다(jsonwebtoken decode.rs L283 — alg 미포함 시 InvalidAlgorithm).
    #[tokio::test]
    async fn rejects_alg_confusion_hs256_with_rsa_pubkey() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut h = Header::new(Algorithm::HS256);
        h.kid = Some("test-kid".into()); // 정상 kid로 위장 → JWKS의 RSA 키를 로드하게 유도
        let ek = EncodingKey::from_secret(fx.pub_pem.as_bytes()); // 공개키 텍스트 = HMAC 비밀(고전 공격)
        let token = encode(&h, &good_claims(), &ek).unwrap();
        assert!(
            matches!(
                v.validate(&token).await,
                Err(KeycloakError::TokenValidation(_))
            ),
            "HS256 alg-confusion token MUST be rejected by the RS256 pin"
        );
    }

    /// alg="none" 무서명 토큰: 헤더를 직접 base64url 조립(jsonwebtoken은 none을 인코딩하지 않음).
    /// Algorithm enum에 none 변형이 없어 decode_header에서 구조적으로 거부된다.
    #[tokio::test]
    async fn rejects_none_alg() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let header = json!({ "alg":"none", "typ":"JWT", "kid":"test-kid" });
        let token = format!(
            "{}.{}.",
            b64(header.to_string().as_bytes()),
            b64(good_claims().to_string().as_bytes())
        );
        assert!(
            matches!(
                v.validate(&token).await,
                Err(KeycloakError::TokenValidation(_))
            ),
            "alg=none token MUST be rejected"
        );
    }

    /// iss 접미사 공격: 기대 issuer + 접미사("...it-realm-evil"). set_issuer는 정확 일치이므로
    /// 접두/부분 매칭으로 통과해서는 안 된다.
    #[tokio::test]
    async fn rejects_issuer_superstring() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims();
        c["iss"] = json!("http://kc:8080/realms/it-realm-evil");
        assert!(
            matches!(
                v.validate(&sign(&fx, c, "test-kid")).await,
                Err(KeycloakError::TokenValidation(_))
            ),
            "issuer superstring MUST be rejected (exact match, not prefix)"
        );
    }

    /// aud 부분문자열 공격: aud=["it-client-evil"]는 "it-client"를 부분문자열로 포함하지만
    /// set_audience는 집합 정확 멤버십이므로 거부되어야 한다.
    #[tokio::test]
    async fn rejects_aud_substring() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims();
        c["aud"] = json!(["it-client-evil"]);
        assert!(
            matches!(
                v.validate(&sign(&fx, c, "test-kid")).await,
                Err(KeycloakError::TokenValidation(_))
            ),
            "aud substring MUST be rejected (exact set-membership, not substring)"
        );
    }

    /// 미래 nbf: 유효 서명이지만 nbf=now+3600. validate_nbf=true가 활성이어야 거부된다
    /// (jsonwebtoken 기본 false이므로 강화가 없으면 이 토큰은 통과한다 — 강화 활성 증명).
    #[tokio::test]
    async fn rejects_future_nbf() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims();
        c["nbf"] = json!(now() + 3600);
        assert!(
            matches!(
                v.validate(&sign(&fx, c, "test-kid")).await,
                Err(KeycloakError::TokenValidation(_))
            ),
            "future nbf MUST be rejected (validate_nbf=true active)"
        );
    }

    // ── 보안 하드닝 리뷰 후속: 악성/기형 JWKS 클래스 + 스큐 경계(리뷰 Important+Minor) ──

    /// 악성 JWKS: RSA `n`이 JSON 배열(문자열이 아님). PHP SDK 자매 구현에서 이 클래스가
    /// 일반 리뷰를 뚫고 Critical(경계 미변환 예외 누출)로 실제 배포된 전례가 있다.
    /// 핵심 불변식은 **"panic이 아니라 깨끗한 Err"**(= fail-closed)이며, 그 Err가 어느 단계에서
    /// 나오는지는 하위 크레이트의 관용에 달려 있다.
    ///
    /// ⚠️ jsonwebtoken 11.0.0에서 거부 **단계가 옮겨졌다**("JWKs with unknown key types are now
    /// deserializable"). 10.x는 `JwkSet` serde 역직렬화가 타입 불일치로 실패해 `JwksStore::fetch`가
    /// `Transport`로 흡수했지만, 11.x는 RSA 변형 매칭에 실패한 이 키를 unknown 키타입으로
    /// 역직렬화에 성공시킨다 → 세트는 파싱되고 kid도 찾히며, 한 단계 뒤 `DecodingKey::from_jwk`가
    /// 거부해 `TokenValidation`이 된다(아래 `rejects_jwks_with_invalid_base64_n`과 같은 경로).
    /// 거부 자체는 그대로이므로 fail-closed는 유지된다 — 오히려 **세트 전체가 죽지 않는** 쪽이
    /// 안전하다(`tolerates_unknown_kty_alongside_valid_key` 참고).
    #[tokio::test]
    async fn rejects_jwks_with_n_as_array() {
        let fx = make_key();
        let token = sign(&fx, good_claims(), "test-kid");
        let malformed = json!({ "keys": [ { "kty":"RSA","kid":"test-kid","use":"sig",
            "alg":"RS256","n":["not","a","string"],"e":"AQAB" } ] });
        let v = validator_with_raw_jwks(malformed).await;
        match v.validate(&token).await {
            Err(KeycloakError::TokenValidation(_)) => {} // 기대: from_jwk 거부 → 깨끗한 Err(panic 아님)
            other => panic!(
                "malformed JWKS (n as JSON array) MUST yield a clean Err(TokenValidation(_)), not panic — got {other:?}"
            ),
        }
    }

    /// jsonwebtoken 11.0.0을 수용한 **근거**를 고정하는 회귀 테스트.
    ///
    /// 10.x에서는 JWKS에 우리가 모르는 `kty` 키가 **하나라도** 섞이면 `JwkSet` 역직렬화가 통째로
    /// 실패해 같은 세트의 멀쩡한 RSA 키까지 못 쓰고 **모든 검증이 죽었다**. Keycloak이 realm에
    /// EdDSA 등 키를 추가하면 그대로 발현하는 가용성 사고다. 11.x는 미지 키타입을 관용하므로
    /// 유효한 키로 서명된 토큰은 계속 검증된다 — 이 성질이 깨지면 상향을 되돌려야 한다.
    #[tokio::test]
    async fn tolerates_unknown_kty_alongside_valid_key() {
        let fx = make_key();
        let token = sign(&fx, good_claims(), "test-kid");
        // 미지 kty 키가 유효한 RSA 키보다 **앞에** 오도록 배치(순회 중 조기 실패 방지 확인).
        let mixed = json!({ "keys": [
            { "kty":"OKP","kid":"future-kid","use":"sig","alg":"EdDSA","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo" },
            fx.jwk,
        ] });
        let v = validator_with_raw_jwks(mixed).await;
        let out = v.validate(&token).await;
        assert!(
            out.is_ok(),
            "unknown-kty key in the set MUST NOT disable the valid RSA key — got {out:?}"
        );
        assert_eq!(out.unwrap().subject, "s1");
    }

    /// 악성 JWKS: RSA `n`이 문법적으로 유효한 JSON 문자열이지만 base64url이 아니다.
    /// `JwkSet` 역직렬화는 통과(String 타입 일치)하지만 `DecodingKey::from_jwk`의 base64
    /// 디코드 단계에서 실패한다 — `JwtValidator::validate`가 이를 `KeycloakError::TokenValidation`
    /// 으로 흡수해야 한다(panic/unwrap 없이).
    #[tokio::test]
    async fn rejects_jwks_with_invalid_base64_n() {
        let fx = make_key();
        let token = sign(&fx, good_claims(), "test-kid");
        let malformed = json!({ "keys": [ { "kty":"RSA","kid":"test-kid","use":"sig",
            "alg":"RS256","n":"!!!not-base64!!!","e":"AQAB" } ] });
        let v = validator_with_raw_jwks(malformed).await;
        match v.validate(&token).await {
            Err(KeycloakError::TokenValidation(_)) => {} // 기대: from_jwk 실패 → 깨끗한 TokenValidation(panic 아님)
            other => panic!(
                "malformed JWKS (n not valid base64url) MUST yield a clean Err(TokenValidation(_)), not panic — got {other:?}"
            ),
        }
    }

    /// 클록 스큐 경계: exp가 45초 전(만료). config leeway=30이므로 거부되어야 한다
    /// (jsonwebtoken 기본 leeway=60이었다면 이 토큰은 통과했을 것 — 강화된 30이 실제로
    /// 적용되고 있음을 증명, 불변식 6).
    #[tokio::test]
    async fn rejects_expired_beyond_config_skew() {
        let fx = make_key();
        let v = validator_for(&fx).await;
        let mut c = good_claims();
        c["exp"] = json!(now() - 45);
        assert!(
            matches!(
                v.validate(&sign(&fx, c, "test-kid")).await,
                Err(KeycloakError::TokenValidation(_))
            ),
            "exp 45s in the past MUST be rejected under configured leeway=30 \
             (jsonwebtoken's default leeway=60 would have accepted it)"
        );
    }
}
