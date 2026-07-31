# 배포 전 감사 잔여분 해소 — WBS

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` 또는 `superpowers:executing-plans`로 태스크 단위 실행. 스텝은 체크박스(`- [ ]`)로 추적한다.

**Goal:** 감사에서 확인된 잔여 결함(공격 프로브 공백·리다이렉트 발산·버전 SSOT 취약)을 해소해, "아홉 언어가 동형으로 하드닝됐다"는 주장을 테스트로 뒷받침한다.

**Architecture:** 새 기능이 아니라 **기존 불변식을 증명하는 테스트**와 **명시적 하드닝**을 채운다. 각 언어의 기존 테스트 픽스처를 재사용하고 새 의존성을 도입하지 않는다.

**Tech Stack:** 언어별 기존 테스트 스택 그대로 — Go `httptest`+go-jose · Java JUnit5+Nimbus · Node vitest+jose · Python pytest+joserfc · .NET xUnit+WireMock.Net · Kotlin JUnit5+WireMock · PHP PHPUnit · Rust `#[tokio::test]`+wiremock · Ruby RSpec+webmock

**Spec:** [2026-07-31-pre-release-audit-remediation.md](../specs/2026-07-31-pre-release-audit-remediation.md)

## 진행 상태 (2026-07-31)

| Task | 상태 | 커밋 | 비고 |
|---|---|---|---|
| 1. Go HS/RS 혼동 | ✅ 완료 | `dbc4e9a` | 변이검증: 막는 것은 alg 핀이 아니라 키 소스 분리 |
| 2. Java 기형 JWKS | ✅ 완료 | `aa7f5bc` | 변이검증: 던지는 타입을 바꾸면 실패 |
| 3. Node 기형 JWKS | ✅ 완료 | `ee710ae` | 변이검증: 경계 변환 제거 시 이 테스트만 실패 |
| 4. Python 기형 JWKS | ✅ 완료 | `e697d61` | **실제 결함 발견** — `binascii.Error`가 경계를 뚫고 나갔다. sync·async 둘 다 수정 |
| 5. Java·.NET 위조서명 무재조회 | ⚠️ 부분 | `aa7f5bc`·`77f4bc8` | **.NET은 이 불변식을 갖지 못함이 실측됨** — 0회가 아니라 rate-limit 상한만 고정 |
| 6. 리다이렉트 SSRF 차단 | ✅ 완료 | `61f65f8`·`7b3dd3e`·`5808d3a`·`b2014d6`·`14059dc`·`e92316b` | **9개 언어 전부**. 7개가 실제로 취약했다 |
| 7. 버전 SSOT 가드 | ✅ 완료 | `7aa7959` | 자가테스트 5건(변이 3 + 오탐방지 1 포함) |
| 8. admin 능력 매트릭스 | ⬜ 미착수 | — | |

**Task 6 후속 판단 필요**: .NET은 핸들러가 `KeycloakClient.Create` 안에서 만들어지고 외부 시임이 없어 행동 테스트를 붙이지 못했다. 시임을 열 것인지(공개 표면 증가) 리플렉션으로 단언할 것인지 결정이 필요하다.

---

### Task 6 정정 — Grok 실측이 계획의 전제를 반박했다 (2026-07-31)

이 태스크의 Step 1이 "추측 금지, 실측"이었는데, **계획 본문에 적어둔 기본값 자체가 틀려 있었다.** Grok이 로컬 302 서버로 전 언어를 실행 측정해 반박했고, 아래는 그 결과다. 원문 서술은 남겨두고 여기서 정정한다 — 무엇이 왜 틀렸는지가 다음 사람에게 더 중요하다.

**정정 1 — "Guzzle은 기본 미추종"은 틀렸다.** PSR-18 `sendRequest()`만 미추종이고 `request()`는 **추종한다**(`vendor/guzzlehttp/guzzle/src/Client.php:342`가 `RedirectMiddleware::$defaultSettings`를 기본값으로 넣는다 — 직접 확인). 이 한 줄을 믿었으면 PHP를 건너뛰었을 것이고, PHP는 **`client_secret_basic` 헤더가 공격자가 고른 경로로 재전송되는 것이 실측된** 언어다.

**정정 2 — "언어당 HTTP 클라이언트 하나"라는 전제가 틀렸다.** Java 3개 · Node 4개 · PHP 3개+ · Python 2개이고, Java·Node·PHP는 **일부만 안전한 혼재 상태**다. 눈에 띄는 하나를 고치고 끝내면 세 언어 모두 구멍이 남는다.

**정정 3 — 계획이 지목한 JVM 수정 대상이 틀렸다.** "RESTEasy 구성에서 followRedirects(false)"라고 썼는데 RESTEasy admin은 **이미 안전**하고 JAX-RS `ClientBuilder`에는 그런 메서드가 없다. 실제로 취약한 두 경로는 Nimbus `HTTPRequest`(auth)와 `DefaultResourceRetriever`(JWKS)였다.

**정정 4 — Python 수정안이 구현 불가였다.** "요청 시 `allow_redirects=False`"는 SDK가 요청을 보낸다는 전제인데, 실제로는 python-keycloak이 보내고 그 플래그를 넘기지 않는다.

**누락 1 — 자격증명 재전송이 심각도를 결정한다.** same-host 리다이렉트에서 Python(requests)·Node(undici)·PHP(Guzzle)는 `Authorization`을 **재전송**한다(JVM은 안 한다). 이것이 이 결함을 SSRF에서 자격증명 노출로 격상시킨다. 테스트는 "/internal에 도달하지 않았다"만이 아니라 이 점도 반영해야 한다.

**누락 2 — 조용한 거짓 성공.** Kotlin·PHP `logout`은 302를 따라가 무관한 200을 받으면 **정상 반환**했다. 세션이 살아 있는데 호출자는 폐기됐다고 믿는다. "/internal 미도달"만 단언하는 테스트는 302를 삼키고 성공을 반환하는 변형에서도 통과하므로, **표면화된 상태코드까지 단언**해야 한다.

**순서 정정** — 5개 언어 일괄이 아니라 시임 품질 순으로: Java → Kotlin → PHP → Node → **Python 마지막**(공개 노브가 없어 private 속성을 건드리는 유일한 수정이라 회귀 위험이 가장 크고, 단독 커밋이어야 되돌리기 쉽다).

**추가 태스크 — 이미 안전한 경로에 고정(pinning) 테스트.** Java/Kotlin admin · Node jose+openid-client · PHP PSR-18 · Python httpx는 **라이브러리 기본값 덕분에** 안전하다. 이는 §3-2가 막으려던 "업그레이드로 조용히 취약해지는" 바로 그 상태이고, 몇몇은 끌 노브 자체가 없어 **테스트가 유일한 방어수단**이다.

**.NET 후속의 값싼 답** — 시임 노출 vs 리플렉션의 양자택일이 아니었다: `internal static SocketsHttpHandler CreateHandler(KeycloakConfig)` 추출 + `InternalsVisibleTo` + 로컬 `HttpListener`. 공개 표면이 늘지 않으며, Java `buildTimeoutClient`가 이미 같은 모양의 시임을 갖고 있다.

---

## Global Constraints

- 프로덕션 소스를 만지는 것은 **Task 6뿐**이다(Task 7은 병합됨). 나머지는 테스트·문서 전용.
- 새 의존성 추가 금지 — 필요한 것은 전부 이미 dev 의존성에 있다.
- **모든 신규 테스트는 변이검증을 통과해야 한다**: 방어 코드/설정을 지웠을 때 실제로 깨지는지 확인하고, 그 결과를 커밋 메시지에 남긴다. 깨지지 않으면 그 테스트는 무효이며, 무엇이 실제로 막고 있는지 규명해 주석에 적는다.
- 각 언어의 린트·포맷 게이트를 통과해야 한다(gofmt · prettier · php-cs-fixer · ktlint · ruff · rubocop · dotnet format · cargo fmt).
- ⚠️ Windows 워킹트리는 CRLF다. Node prettier 전체 검사는 로컬에서 신뢰할 수 없다 — 변경 파일만 LF 기준으로 확인한다(CLAUDE.md 하드닝 CI 게차).

---

### Task 1: Go — HS/RS 혼동 프로브

**Files:**
- Test: `go/jwt_test.go` (기존 픽스처 `newJWTFixture`/`claims` 재사용)

**Interfaces:**
- Consumes: `jwtFixture{priv, other, jwksSrv, fetches}` · `f.sign(t, key, kid, cl)` · `claims(aud, iss, exp)` · `newValidator(t, f)`
- Produces: 없음(테스트 전용)

- [ ] **Step 1: 실패하는 테스트 작성**

```go
// 공격자가 공개된 RSA 공개키를 HMAC 비밀로 삼아 HS256 토큰을 위조한다. 검증기가 헤더의 alg를
// 믿고 키를 고르면 "공개키를 아는 사람 = 토큰을 발급할 수 있는 사람"이 된다.
func TestValidateRejectsHS256ForgedWithRSAPublicKey(t *testing.T) {
	f := newJWTFixture(t)
	v := newValidator(t, f)

	pubDER, err := x509.MarshalPKIXPublicKey(&f.priv.PublicKey)
	if err != nil {
		t.Fatalf("marshal public key: %v", err)
	}
	sig, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.HS256, Key: pubDER},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "k1"))
	if err != nil {
		t.Fatalf("hmac signer: %v", err)
	}
	forged, err := jwt.Signed(sig).Claims(claims(jwt.Audience{"it-client"},
		f.issuer(), time.Now().Add(5*time.Minute))).Serialize()
	if err != nil {
		t.Fatalf("sign: %v", err)
	}

	if _, err := v.Validate(context.Background(), forged); err == nil {
		t.Fatal("HS256 token forged with the RSA public key MUST be rejected")
	}
}
```

- [ ] **Step 2: 실패 확인**

Run: `go -C go test -run TestValidateRejectsHS256ForgedWithRSAPublicKey ./...`
Expected: 컴파일 실패(`x509` 미import) → import 추가 후 재실행. 이때 **통과하면** 그 방어가 alg 핀인지 키 소스 분리인지 규명해 주석에 적는다(무효 테스트 방지).

- [ ] **Step 3: import 보강**

`go/jwt_test.go` 상단 import 블록에 `"crypto/x509"` 추가.

- [ ] **Step 4: 통과 확인 + 변이검증**

Run: `go -C go test ./...`
변이검증: `jwt.go`의 알고리즘 핀(허용 alg 집합)을 일시 제거하고 재실행 → 이 테스트가 깨지는지 확인. 깨지지 않으면 무엇이 막는지(키 타입 불일치) 주석에 명시.

- [ ] **Step 5: 커밋**

```bash
gofmt -w go/jwt_test.go
git add go/jwt_test.go && git commit -m "test(go): HS/RS 혼동 프로브 추가 — 아홉 언어 동형 최소집합 2번"
```

---

### Task 2: Java — 기형 JWKS 프로브

**Files:**
- Test: `java/keycloak-sdk-auth/src/test/java/io/github/xzawed/keycloak/auth/JwtValidatorTest.java`

**Interfaces:**
- Consumes: `JwtValidator.forRealm(md, cfg, algs, audience)` · Task 이전에 추가된 `countJwksHitsForUnknownKids` 옆의 `com.sun.net.httpserver.HttpServer` 패턴
- Produces: 없음

- [ ] **Step 1: 실패하는 테스트 작성**

```java
/**
 * 기형 JWKS(base64url이 아닌 modulus)는 raw 예외가 아니라 SDK 타입 오류로 나와야 한다.
 * PHP 자매 구현에서 이 클래스가 일반 리뷰를 뚫고 Critical(경계 미변환 예외 누출)로 배포된 전례가 있다.
 */
@Test void malformedJwks_yieldsSdkError_notRawException() throws Exception {
  com.sun.net.httpserver.HttpServer server =
      com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
  byte[] body = ("{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"k1\",\"use\":\"sig\",\"alg\":\"RS256\","
      + "\"n\":\"!!!not-base64!!!\",\"e\":\"AQAB\"}]}")
      .getBytes(java.nio.charset.StandardCharsets.UTF_8);
  server.createContext("/realms/r/protocol/openid-connect/certs", ex -> {
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(200, body.length);
    try (java.io.OutputStream os = ex.getResponseBody()) { os.write(body); }
  });
  server.start();
  try {
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
            .realm("r").clientId("app").build();
    OidcMetadata md = OidcMetadata.forRealm(cfg);
    JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");
    RSAKey signing = new RSAKeyGenerator(2048).keyID("k1").generate();
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(md.getIssuer()).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(signing));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(jwt.serialize()));
  } finally {
    server.stop(0);
  }
}
```

- [ ] **Step 2: 실패/통과 확인**

Run: `JAVA_HOME=... PATH=...maven/bin:$PATH mvn -f java/pom.xml test -pl keycloak-sdk-auth -am -Dtest=JwtValidatorTest -Dsurefire.failIfNoSpecifiedTests=false`
Expected: 통과해야 정상(이미 `validate`가 모든 예외를 `TokenValidationException`으로 감싼다). **통과하면 그 자체가 계약 확인**이므로, 무효가 아님을 보이기 위해 Step 3의 변이검증을 반드시 수행한다.

- [ ] **Step 3: 변이검증**

`JwtValidator.validate`의 `catch (Exception e)` 절을 일시적으로 좁혀(`catch (com.nimbusds.jose.proc.BadJOSEException e)`) 재실행 → 이 테스트가 깨지는지 확인. 깨지면 계약이 실제로 이 테스트에 의해 지켜진다는 뜻이다. 원복한다.

- [ ] **Step 4: 커밋**

```bash
git add java/keycloak-sdk-auth/src/test/java/io/github/xzawed/keycloak/auth/JwtValidatorTest.java
git commit -m "test(java): 기형 JWKS가 SDK 타입 오류로 나오는지 고정 — 동형 최소집합 5번"
```

---

### Task 3: Node — 기형 JWKS 프로브

**Files:**
- Test: `node/test/unit/jwt-jwks.test.ts` (이미 로컬 HTTP 서버로 JWKS를 서빙한다 — 그 서버 재사용)

**Interfaces:**
- Consumes: `JwtValidator.forJwksUri(jwksUri, opts)` · 파일 상단의 `createServer`/`jwksUri`/`hits` 패턴
- Produces: 없음

- [ ] **Step 1: 실패하는 테스트 작성**

```ts
it('기형 JWKS(base64url 아닌 modulus) → raw 예외가 아니라 KeycloakTokenValidationError', async () => {
  const bad = createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(
      JSON.stringify({
        keys: [{ kty: 'RSA', kid: 'k1', use: 'sig', alg: 'RS256', n: '!!!not-base64!!!', e: 'AQAB' }],
      }),
    )
  })
  await new Promise<void>((r) => bad.listen(0, '127.0.0.1', r))
  try {
    const uri = `http://127.0.0.1:${(bad.address() as AddressInfo).port}/certs`
    const v = JwtValidator.forJwksUri(uri, { ...baseOpts, jwksMinRefetchSeconds: 30 })
    const token = await new SignJWT({ sub: 'u', aud: 'my-client' })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(ISS)
      .setIssuedAt()
      .setExpirationTime('5m')
      .sign(attackerKey)
    await expect(v.validate(token)).rejects.toBeInstanceOf(KeycloakTokenValidationError)
  } finally {
    await new Promise<void>((r) => bad.close(() => r()))
  }
})
```

- [ ] **Step 2: import 보강**

`jwt-jwks.test.ts` 상단에 `import { KeycloakTokenValidationError } from '../../src/errors.js'` 추가.

- [ ] **Step 3: 실행**

Run: `cd node && npx vitest run test/unit/jwt-jwks.test.ts`

- [ ] **Step 4: 변이검증**

`src/jwt.ts`의 `catch` 절을 제거해 raw jose 오류가 새게 만든 뒤 재실행 → 깨지는지 확인. 원복.

- [ ] **Step 5: 포맷·커밋**

```bash
cd node && npx prettier --write test/unit/jwt-jwks.test.ts
git add node/test/unit/jwt-jwks.test.ts
git commit -m "test(node): 기형 JWKS가 SDK 오류 계급으로 변환되는지 고정 — 동형 최소집합 5번"
```

---

### Task 4: Python — 기형 JWKS 프로브

**Files:**
- Test: `python/tests/unit/test_jwt.py` (픽스처 `_rsa_key`/`_sign`/`KeySet` 재사용)

**Interfaces:**
- Consumes: `JwtValidator.validate(token, key_set)` · `keycloak_sdk.exceptions.TokenValidationError`
- Produces: 없음

- [ ] **Step 1: 실패하는 테스트 작성**

```python
def test_malformed_jwks_key_yields_token_validation_error() -> None:
    """기형 JWK(base64url 아닌 modulus)는 joserfc 예외가 아니라 SDK 타입 오류로 나와야 한다."""
    key = _rsa_key()
    tok = _sign(key, {"sub": "s1", "iss": ISS, "aud": ["it-client"], "exp": _now() + 300})
    malformed = {"keys": [{"kty": "RSA", "kid": "test-kid", "use": "sig",
                           "alg": "RS256", "n": "!!!not-base64!!!", "e": "AQAB"}]}
    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet.import_key_set(malformed))
```

> ⚠️ `KeySet.import_key_set`이 기형 키에서 즉시 던질 수 있다. 그 경우 테스트는 **SDK 경계 바깥**을 검증하게 되므로, 대신 `validator.validate`에 raw dict를 넘기는 SDK 공개 경로가 있는지 확인하고 그 경로로 바꾼다. 없으면 이 태스크는 "해당 없음"으로 종결하고 그 사실을 스펙 §5에 기록한다.

- [ ] **Step 2: 실행**

Run: `cd python && .venv/Scripts/python.exe -m pytest tests/unit/test_jwt.py -q -p no:warnings`

- [ ] **Step 3: 변이검증**

`keycloak_sdk/jwt.py`의 예외 변환 절을 제거해 joserfc 예외가 새게 만든 뒤 재실행 → 깨지는지 확인. 원복.

- [ ] **Step 4: 커밋**

```bash
cd python && .venv/Scripts/python.exe -m ruff format tests/unit/test_jwt.py && .venv/Scripts/python.exe -m ruff check tests/unit/test_jwt.py
git add python/tests/unit/test_jwt.py
git commit -m "test(python): 기형 JWKS가 SDK 오류로 변환되는지 고정 — 동형 최소집합 5번"
```

---

### Task 5: Java·.NET — 위조 서명은 JWKS 재조회를 유발하지 않는다

**Files:**
- Test: `java/.../JwtValidatorTest.java` · `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/JwtValidatorTests.cs`

**Interfaces:**
- Consumes: Java `countJwksHitsForUnknownKids`(PR #115에서 추가) · .NET `CountJwksHitsAsync`(동)
- Produces: 없음

핵심 불변식: **미해결 kid**는 재조회를 유발하되 rate-limit되고, **알려진 kid + 잘못된 서명**은 재조회를 **전혀** 유발하지 않아야 한다. 후자가 재조회를 유발하면 공격자는 서명만 바꿔가며 IdP를 때릴 수 있다(Python·Go·Rust·Ruby는 이미 고정).

- [ ] **Step 1: Java 테스트 작성**

```java
/** 알려진 kid + 위조 서명은 JWKS 재조회를 **전혀** 유발하지 않아야 한다(서명위조 DoS 증폭 차단). */
@Test void forgedSignatureWithKnownKid_doesNotRefetchJwks() throws Exception {
  RSAKey served = new RSAKeyGenerator(2048).keyID("k1").generate();
  RSAKey attacker = new RSAKeyGenerator(2048).keyID("k1").generate(); // 같은 kid, 다른 키
  java.util.concurrent.atomic.AtomicInteger hits = new java.util.concurrent.atomic.AtomicInteger();
  com.sun.net.httpserver.HttpServer server =
      com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
  byte[] body = new JWKSet(served.toPublicJWK()).toString()
      .getBytes(java.nio.charset.StandardCharsets.UTF_8);
  server.createContext("/realms/r/protocol/openid-connect/certs", ex -> {
    hits.incrementAndGet();
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(200, body.length);
    try (java.io.OutputStream os = ex.getResponseBody()) { os.write(body); }
  });
  server.start();
  try {
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
            .realm("r").clientId("app").build();
    OidcMetadata md = OidcMetadata.forRealm(cfg);
    JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");
    // 최초 1회는 JWKS를 받아야 한다(정상 경로).
    SignedJWT good = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(md.getIssuer()).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    good.sign(new RSASSASigner(served));
    v.validate(good.serialize());
    int afterWarmup = hits.get();

    for (int i = 0; i < 8; i++) {
      SignedJWT forged = new SignedJWT(
          new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
          new JWTClaimsSet.Builder().issuer(md.getIssuer()).audience("app")
              .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
      forged.sign(new RSASSASigner(attacker));
      final String s = forged.serialize();
      assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
          () -> v.validate(s));
    }
    assertEquals(afterWarmup, hits.get(),
        "위조 서명(알려진 kid)은 JWKS 재조회를 유발하면 안 된다 — 서명위조 DoS 증폭 경로");
  } finally {
    server.stop(0);
  }
}
```

- [ ] **Step 2: Java 실행**

Run: `mvn -f java/pom.xml test -pl keycloak-sdk-auth -am -Dtest=JwtValidatorTest -Dsurefire.failIfNoSpecifiedTests=false`

- [ ] **Step 3: .NET 동형 테스트 작성**

`CountJwksHitsAsync`와 같은 WireMock 패턴을 쓰되, 위조 토큰의 kid를 **서빙 중인 kid와 동일**하게 두고 서명 키만 다르게 한다. 워밍업 1회 후 히트 수가 증가하지 않음을 단언한다.

- [ ] **Step 4: .NET 실행**

Run: `cd dotnet && dotnet test --filter "FullyQualifiedName~JwtValidatorTests"`

- [ ] **Step 5: 커밋**

```bash
git add java/keycloak-sdk-auth/src/test/.../JwtValidatorTest.java dotnet/tests/.../JwtValidatorTests.cs
git commit -m "test(java,dotnet): 위조 서명이 JWKS 재조회를 유발하지 않음을 고정 — 동형 최소집합 4번"
```

---

### Task 6: 리다이렉트(SSRF) 명시 차단 — 7개 언어

**Files (production — 이 WBS에서 프로덕션을 만지는 유일한 태스크):**
- Modify: `java/keycloak-sdk-*/src/main/.../` HTTP 클라이언트 구성 지점
- Modify: `kotlin/src/main/kotlin/io/github/xzawed/keycloak/` 동
- Modify: `node/src/` transport 구성
- Modify: `python/src/keycloak_sdk/` requests/httpx 세션 구성
- Modify: `go/` `http.Client` 구성
- Modify: `dotnet/src/Xzawed.Keycloak.Sdk/` `SocketsHttpHandler`
- Modify: `php/src/` Guzzle 구성
- Test: 각 언어 단위 테스트에 "3xx를 따라가지 않는다" 케이스

**Interfaces:**
- Consumes: 각 언어의 기존 HTTP 클라이언트 팩토리
- Produces: 동작 변경 없음(기본이 이미 미추종인 언어) 또는 명시 차단(추종이 기본인 언어)

- [ ] **Step 1: 언어별 현재 기본값 실측**

각 언어의 HTTP 클라이언트가 **기본적으로 3xx를 따라가는지** 로컬 HTTP 서버(302 → 다른 경로)로 실측해 표를 만든다. 추측 금지 — Go `http.Client`는 기본 추종(최대 10회), .NET `SocketsHttpHandler.AllowAutoRedirect`는 기본 true, Guzzle은 기본 미추종, requests는 기본 추종이다. **각 언어에서 직접 확인한 값만 표에 넣는다.**

- [ ] **Step 2: 추종이 기본인 언어부터 실패 테스트 작성**

패턴(Go 예):

```go
func TestHTTPClientDoesNotFollowRedirects(t *testing.T) {
	var reached int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/internal" {
			atomic.AddInt32(&reached, 1)
			w.WriteHeader(http.StatusOK)
			return
		}
		http.Redirect(w, r, "/internal", http.StatusFound)
	}))
	defer srv.Close()

	resp, err := newHTTPClient(cfg).Get(srv.URL + "/start")
	if err == nil {
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusFound {
			t.Fatalf("expected the 302 to be surfaced, got %d", resp.StatusCode)
		}
	}
	if atomic.LoadInt32(&reached) != 0 {
		t.Fatal("SSRF hardening: the SDK must not follow redirects to an unexpected host/path")
	}
}
```

- [ ] **Step 3: 언어별 최소 구현**

Go `CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }` · .NET `new SocketsHttpHandler { AllowAutoRedirect = false }` · Python `session.max_redirects`가 아니라 요청 시 `allow_redirects=False` · Java/Kotlin RESTEasy/HttpClient 구성에서 `followRedirects(false)` · Node fetch 기반이면 `redirect: 'error'`.

- [ ] **Step 4: 실행 + 변이검증**

각 언어 단위 스위트 실행 후, 차단 설정을 되돌려 테스트가 깨지는지 확인.

- [ ] **Step 5: 커밋(언어별로 나눠서)**

```bash
git commit -m "fix(<lang>): back-channel HTTP 리다이렉트를 명시 차단한다 — SSRF 하드닝 동형화"
```

---

### Task 7: 버전 SSOT 가드

**Files:**
- Modify: `scripts/check-docs.mjs` (또는 신규 `scripts/check-versions.mjs`)
- Modify: `.github/workflows/repo-hygiene.yml` (가드 실행 배선)

**Interfaces:**
- Consumes: `scripts/lib/deploy-facts.sh`의 `df_versionbump`
- Produces: 어긋나면 `::error::` + exit 1

- [ ] **Step 1: 실패하는 가드 작성**

Java 7개 POM의 `<version>`이 서로 다르면 실패, dotnet csproj `<Version>`이 존재하는데 릴리스가 `-p:Version`으로 덮어쓴다는 사실이 문서화되지 않으면 실패.

- [ ] **Step 2: 현재 저장소에서 통과하는지 확인**

Run: `node scripts/check-versions.mjs`
Expected: PASS(현재는 일치)

- [ ] **Step 3: 변이검증**

POM 하나의 버전을 임시로 바꿔 가드가 실패하는지 확인 후 원복.

- [ ] **Step 4: CI 배선 + 커밋**

---

### Task 8: admin 능력 매트릭스 문서

**Files:**
- Modify: `docs/guides/getting-started.md` (영문)

- [ ] **Step 1: 아홉 언어 admin 표면 실측**

각 언어 `admin/`에서 users·clients·realms·roles·groups 리소스별 CRUD 메서드를 grep으로 열거한다.

- [ ] **Step 2: 매트릭스 표 작성**

없는 메서드는 빈칸이 아니라 **대체 경로**(raw 탈출구)를 적는다.

- [ ] **Step 3: doc-facts 통과 확인 + 커밋**

---

## Self-Review

**스펙 커버리지**: §3-1 6개 불변식 → Task 1~5(1·2·4·5번 항목; 3·6번은 PR #115에서 완료) · §3-2 → Task 6 · §3-3 → Task 8 · §3-4 → Task 7. 누락 없음.

**남은 위험**: Task 6이 프로덕션 동작을 바꾸는 유일한 태스크다. 언어별 기본값을 **실측 없이 가정하면 안 된다**(Step 1이 그래서 실측 태스크다). Task 4는 Python joserfc의 `KeySet` 경계 때문에 "해당 없음"으로 끝날 수 있으며, 그 경우 그렇게 기록하는 것이 정답이다.
