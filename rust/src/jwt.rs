//! 자체강화 JWT 검증: RS256 핀(헤더 alg 미신뢰)·none 구조적 거부·iss 정확·aud 포함·exp 필수·nbf·스큐·DoS-safe JWKS.
use crate::config::KeycloakConfig;
use crate::error::{KeycloakError, Result};
use crate::jwks::JwksStore;
use crate::oidc::OidcEndpoints;
use crate::tokens::ValidatedToken;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use serde::Deserialize;

#[derive(Deserialize)]
struct Claims {
    sub: Option<String>,
    iss: Option<String>,
    #[serde(default)]
    aud: AudField,
    exp: Option<u64>,
    iat: Option<u64>,
}

// aud는 string 또는 array — jsonwebtoken이 aud 포함검사를 하지만, ValidatedToken 매핑용으로 벡터화.
#[derive(Deserialize, Default)]
#[serde(untagged)]
enum AudField {
    One(String),
    Many(Vec<String>),
    #[default]
    None,
}
impl AudField {
    fn into_vec(self) -> Vec<String> {
        match self {
            AudField::One(s) => vec![s],
            AudField::Many(v) => v,
            AudField::None => vec![],
        }
    }
}

pub struct JwtValidator {
    issuer: String,
    audience: String,
    clock_skew: u64,
    jwks: JwksStore,
}

impl JwtValidator {
    pub fn new(config: &KeycloakConfig, endpoints: &OidcEndpoints, jwks: JwksStore) -> Self {
        Self {
            issuer: endpoints.issuer(),
            audience: config.client_id.clone(),
            clock_skew: config.clock_skew,
            jwks,
        }
    }

    pub async fn validate(&self, token: &str) -> Result<ValidatedToken> {
        // (1) 헤더에서 kid만 추출(alg는 검증 선택에 미사용 — RS256 고정 핀).
        //     Algorithm enum에는 `none` 변형이 없어 alg="none" 헤더는 여기서 구조적으로 거부된다.
        let header = jsonwebtoken::decode_header(token)
            .map_err(|e| KeycloakError::TokenValidation(format!("malformed JWT header: {e}")))?;
        let kid = header
            .kid
            .as_deref()
            .ok_or_else(|| KeycloakError::TokenValidation("missing kid".into()))?;

        // (2) JWKS에서 kid로 키 → DecodingKey (미해결 kid만 DoS-safe 재조회).
        let jwk = self.jwks.get_key(kid).await?;
        let key = DecodingKey::from_jwk(&jwk)
            .map_err(|e| KeycloakError::TokenValidation(format!("bad JWKS key: {e}")))?;

        // (3) 강화 Validation: RS256 핀·iss 정확·aud 포함·exp 필수·nbf·스큐.
        let mut v = Validation::new(Algorithm::RS256);
        v.algorithms = vec![Algorithm::RS256]; // 헤더 alg 무시하고 RS256만 허용(HS256 confusion·none 차단)
        v.set_issuer(&[self.issuer.as_str()]); // 정확 일치(부분/접두/후행슬래시 변형 거부)
        v.set_audience(&[self.audience.as_str()]); // 집합 정확 포함(부분문자열 아님)
        v.validate_exp = true; // exp 검증
        v.validate_nbf = true; // 기본 false → 강화(미래 nbf 거부)
        v.leeway = self.clock_skew; // 기본 60 → config(30)
        v.set_required_spec_claims(&["exp", "iss", "aud"]); // exp/iss/aud 부재 시 거부

        let data = jsonwebtoken::decode::<Claims>(token, &key, &v).map_err(|e| {
            KeycloakError::TokenValidation(format!("token verification failed: {}", e.kind_str()))
        })?;

        let claims = data.claims;
        Ok(ValidatedToken {
            subject: claims.sub.unwrap_or_default(),
            audience: claims.aud.into_vec(),
            issuer: claims.iss.unwrap_or_default(),
            expires_at: claims.exp,
            issued_at: claims.iat,
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
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/certs"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"keys":[fx.jwk]})))
            .mount(&server)
            .await;
        // server 수명: MockServer는 drop되면 종료되므로, validator의 JWKS fetch가 성립하도록
        // Box::leak로 유지(테스트 전용 — 실제 코드 아님).
        let cfg = KeycloakConfig::new("http://kc:8080", "it-realm", "it-client").unwrap();
        let endpoints = OidcEndpoints::new(&cfg);
        let jwks_uri = format!("{}/certs", Box::leak(Box::new(server)).uri());
        let store = JwksStore::new(jwks_uri, reqwest::Client::new(), 60);
        JwtValidator::new(&cfg, &endpoints, store)
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
}
