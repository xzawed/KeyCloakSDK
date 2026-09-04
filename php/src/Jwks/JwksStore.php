<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Jwks;

use Psr\Http\Client\ClientExceptionInterface;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestFactoryInterface;
use Xzawed\Keycloak\Exception\KeycloakTransportError;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\Exception\TokenValidationError;

/**
 * DoS-safe JWKS 스토어: kid로 캐시, 미해결 kid에만 재조회, 재조회는 rate-limit.
 * 위조 서명(잘못된 kid) 스팸이 IdP를 때리는 미인증 DoS 증폭을 차단한다.
 */
final class JwksStore
{
    /**
     * ⚠️ **실패한 fetch 의 백오프 — `minRefetchIntervalSeconds` 와 다른 축이다.**
     * 30초 게이트는 *캐시가 찬 뒤* 미해결 kid 홍수를 막는다. 아래 둘은 **캐시가 비어 있고 fetch 가
     * 계속 실패할 때**를 막는다 — 그 자리에는 게이트가 없어서, 측정상 20회 조회가 IdP 요청 20건을
     * 그대로 냈다(2026-09-04 · 7개 언어 동일).
     *
     * ⚠️ **여기에 30초를 재사용하면 안 된다** — 일시적 503 한 번이 「30초간 어떤 토큰도 검증
     * 불가」가 된다. 그래서 짧게 시작해 지수적으로 늘리고 상한을 둔다.
     *
     * ⚠️ **sleep 하지 않는다.** 백오프 창 안에서는 IdP 를 때리지 않고 즉시 실패시킨다
     * (negative cache). 재시도 페이싱은 소비자 몫이다.
     */
    private const FAILURE_BACKOFF_BASE_SECONDS = 0.2;
    private const FAILURE_BACKOFF_CAP_SECONDS  = 5.0;

    /** @var array<string,array<string,mixed>> kid → JWK */
    private array $keys = [];
    private bool $loadedOnce = false;
    private ?int $lastRefetchAt = null;
    private int $failures = 0;
    /** 마지막 fetch 실패 시각(monotonic 초). `time()`은 1초 해상도라 0.2초 창을 잴 수 없다. */
    private ?float $lastFailureAt = null;

    public function __construct(
        private readonly string $jwksUri,
        private readonly ClientInterface $http,
        private readonly RequestFactoryInterface $requestFactory,
        // ⚠️ 기본값을 여기 숫자로 적지 말 것 — `KeycloakConfig`가 유일한 정의 자리다. 이 클래스는
        // `final class` + public 생성자라 소비자가 파사드를 거치지 않고 직접 생성할 수 있고,
        // 예전에는 그 경로가 문서의 30이 아니라 60을 받았다(2026-08-13 Task D1).
        private readonly int $minRefetchIntervalSeconds = KeycloakConfig::DEFAULT_JWKS_MIN_REFETCH_SECONDS,
        /**
         * 시계 이음매 — 테스트가 백오프 창을 결정적으로 넘길 수 있어야 한다(sleep 금지).
         * 기본은 monotonic 시계.
         *
         * @var null|callable():float
         */
        private $monotonic = null,
    ) {}

    /**
     * @return array<string,mixed> 선택된 JWK
     *
     * @throws TokenValidationError  kid 미해결(재조회 후에도)
     * @throws KeycloakTransportError 네트워크 오류
     */
    public function getKeyByKid(string $kid): array
    {
        if (!$this->loadedOnce) {
            $this->fetch();   // 초기 로드는 rate-limit 소모하지 않음(첫 키회전 허용)
        }
        if (isset($this->keys[$kid])) {
            return $this->keys[$kid];
        }
        // 미해결 kid → 조건부 재조회(rate-limit)
        $now = \time();
        if ($this->lastRefetchAt !== null && ($now - $this->lastRefetchAt) < $this->minRefetchIntervalSeconds) {
            throw new TokenValidationError(sprintf('unknown kid "%s" (refetch rate-limited)', $kid));
        }
        // 재조회 *결정 시점*에 stamp — fetch가 실패(IdP 장애)해도 게이트가 소모되도록 한다.
        // stamp-after-fetch면 실패한 fetch가 lastRefetchAt을 갱신하지 못해, 위조 kid 스팸이
        // IdP를 무제한 때린다(미인증 DoS 증폭). Rust/Go/Python/Ruby 동형.
        $this->lastRefetchAt = $now;
        $this->fetch();
        if (isset($this->keys[$kid])) {
            return $this->keys[$kid];
        }
        throw new TokenValidationError(sprintf('unknown kid "%s"', $kid));
    }

    private function now(): float
    {
        return ($this->monotonic !== null) ? ($this->monotonic)() : (float) \hrtime(true) / 1e9;
    }

    /** 백오프 잔여 초. 0 이면 fetch 를 허용한다. */
    private function backoffRemaining(): float
    {
        if ($this->lastFailureAt === null) {
            return 0.0;
        }

        return \max(0.0, $this->backoffDelay() - ($this->now() - $this->lastFailureAt));
    }

    /**
     * 지수 백오프 + jitter([0.5, 1.0) 배수). jitter 는 여러 인스턴스가 같은 순간에 복구를
     * 시도해 IdP 를 다시 무너뜨리는 것(thundering herd)을 흩는다. 암호용이 아니라 분산용이다.
     */
    private function backoffDelay(): float
    {
        $raw = self::FAILURE_BACKOFF_BASE_SECONDS * (2 ** (\max($this->failures, 1) - 1));

        return \min($raw, self::FAILURE_BACKOFF_CAP_SECONDS) * (0.5 + \mt_rand() / \mt_getrandmax() / 2);
    }

    /**
     * ⚠️ 백오프 검사는 fetch **직전**이자 30초 게이트 **이후**다. 콜드 캐시에서는 `getKeyByKid`
     * 의 두 분기가 통째로 건너뛰어지므로, 이 게이트가 없으면 매 조회가 IdP 로 나간다(원래 결함).
     */
    private function fetch(): void
    {
        $remaining = $this->backoffRemaining();
        if ($remaining > 0) {
            throw new KeycloakTransportError(sprintf(
                'JWKS fetch backing off after %d consecutive failures (retry in %.2fs)',
                $this->failures,
                $remaining,
            ));
        }
        try {
            $this->fetchOnce();
        } catch (\Throwable $e) {
            $this->failures++;
            $this->lastFailureAt = $this->now();

            throw $e;
        }
        // ⚠️ 성공이 카운터를 되돌리지 않으면 오래 산 프로세스에서 백오프가 상한에 눌러붙는다.
        $this->failures = 0;
        $this->lastFailureAt = null;
    }

    private function fetchOnce(): void
    {
        $request = $this->requestFactory->createRequest('GET', $this->jwksUri);
        try {
            $response = $this->http->sendRequest($request);
        } catch (ClientExceptionInterface $e) {
            throw new KeycloakTransportError('JWKS fetch failed', previous: $e);
        }
        $json = json_decode((string) $response->getBody(), true);
        if ($response->getStatusCode() !== 200 || !is_array($json) || !isset($json['keys']) || !is_array($json['keys'])) {
            throw new KeycloakTransportError('JWKS response invalid');
        }
        $map = [];
        foreach ($json['keys'] as $key) {
            if (!is_array($key)) {
                continue;
            }
            $jwk = self::stringKeyed($key);
            $kid = $jwk['kid'] ?? null;
            if (is_string($kid)) {
                $map[$kid] = $jwk;
            }
        }
        $this->keys = $map;
        $this->loadedOnce = true;
    }

    /**
     * json_decode(..., true)의 배열은 키 타입이 array-key(int|string)로만 추론된다.
     * 신뢰된 JWKS 키 객체는 항상 문자열 키이므로 정수 키(있다면)를 걸러 string-keyed로 좁힌다.
     *
     * @param array<array-key, mixed> $a
     * @return array<string, mixed>
     */
    private static function stringKeyed(array $a): array
    {
        $out = [];
        foreach ($a as $k => $v) {
            if (is_string($k)) {
                $out[$k] = $v;
            }
        }
        return $out;
    }
}
