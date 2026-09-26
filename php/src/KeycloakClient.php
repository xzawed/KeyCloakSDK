<?php

declare(strict_types=1);

namespace Xzawed\Keycloak;

use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\Psr7\HttpFactory;
use Xzawed\Keycloak\Admin\AdminClient;
use Xzawed\Keycloak\Http\HttpOptions;
use Xzawed\Keycloak\Jwks\JwksStore;

/**
 * 통합 진입점: auth 즉시 조립(네트워크 없음), admin은 첫 admin() 호출 시 지연 생성(secret 필요) + 캐시.
 *
 * 네트워크 경계 모듈 — 커버리지 게이트 omit(phpunit.xml). 전체 흐름은 Task 11 통합테스트로 검증.
 */
final class KeycloakClient
{
    private ?AdminClient $adminClient = null;

    private function __construct(
        private readonly KeycloakConfig $config,
        private readonly AuthClient $authClient,
    ) {}

    public static function create(KeycloakConfig $config): self
    {
        $endpoints = new OidcEndpoints($config);
        $guzzle = new GuzzleClient(HttpOptions::guzzle($config));
        $factory = new HttpFactory();
        $jwks = new JwksStore($endpoints->jwks(), $guzzle, $factory, $config->jwksMinRefetchSeconds);
        $validator = new JwtValidator($config, $endpoints, $jwks);
        $auth = new AuthClient($config, $endpoints, $validator, $guzzle);

        return new self($config, $auth);
    }

    public function auth(): AuthClient
    {
        return $this->authClient;
    }

    public function admin(): AdminClient
    {
        return $this->adminClient ??= new AdminClient($this->config);
    }

    /**
     * ⚠️ 덤프 계열은 중첩 객체를 따라간다 — 이 훅이 없을 때 `var_dump($client)` 가 클라이언트 시크릿과 살아 있는
     * PKCE verifier 를 원문으로 찍었다(실측 2026-09-26). 중첩 객체는 각자의 훅으로 가려진다.
     *
     * @return array<string, mixed>
     */
    public function __debugInfo(): array
    {
        return ['config' => $this->config, 'authClient' => $this->authClient, 'adminClient' => $this->adminClient];
    }

    public function close(): void
    {
        // Guzzle/PSR-18은 명시적 커넥션 풀 close가 필요 없다(소켓은 GC/keep-alive 관리).
        // 대칭성/미래대비로 제공 — admin 캐시 해제.
        $this->adminClient = null;
    }
}
