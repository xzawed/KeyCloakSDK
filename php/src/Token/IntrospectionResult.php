<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Token;

use Xzawed\Keycloak\Exception\KeycloakAuthError;

final readonly class IntrospectionResult
{
    /** @param array<string,mixed> $claims */
    public function __construct(
        public bool $active,
        public ?string $username = null,
        public ?string $clientId = null,
        public array $claims = [],
    ) {}

    /**
     * Refuses a response whose `active` is missing or not a JSON boolean with `KeycloakAuthError` — RFC 7662 §2.2 makes it
     * REQUIRED. ⚠️ `$r` is the whole introspection response — trace #0 of that exception is this frame, so without the
     * attribute `var_dump($e)` would print its claims.
     *
     * @param array<string,mixed> $r RFC 7662 introspection response
     */
    public static function fromArray(#[\SensitiveParameter] array $r): self
    {
        // ⚠️ 캐스트하지 않는다 — 예전 `(bool)` 은 문자열 `"false"` 와 `1` 을 **활성**으로 읽었다(fail-open — 게시본 1.0.0–1.5.2,
        // 실측 2026-11-10). 없으면 깨진 응답이지 「비활성」이 아니다 — 토큰 응답에 access_token 이 없는 칸과 같은 auth 계급.
        $active = $r['active'] ?? null;
        if (!\is_bool($active)) {
            throw new KeycloakAuthError('introspection response has no boolean active member');
        }

        return new self(
            active: $active,
            username: isset($r['username']) ? self::toStr($r['username']) : null,
            clientId: isset($r['client_id']) ? self::toStr($r['client_id']) : null,
            claims: $r,
        );
    }

    /** mixed 값을 문자열로 안전하게 좁힌다(신뢰된 introspection 응답의 스칼라 값만 통과). */
    private static function toStr(mixed $v, string $default = ''): string
    {
        return match (true) {
            \is_string($v) => $v,
            \is_int($v), \is_float($v), \is_bool($v) => (string) $v,
            default => $default,
        };
    }
}
