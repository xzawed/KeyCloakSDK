<?php

declare(strict_types=1);

namespace Fixture\Keycloak;

/**
 * Fixture boundary class — some members run in the integration drive, some never do.
 */
final class AuthClient
{
    private string $realm;

    public function __construct(string $realm)
    {
        $this->realm = $realm;
    }

    public function realm(): string
    {
        return $this->realm;
    }

    // Partly run: the drive never sends an empty code, so the throw stays unexecuted.
    public function exchange(string $code): string
    {
        if ($code === '') {
            throw new \InvalidArgumentException('empty code');
        }

        return strtoupper($code);
    }

    // A closure's lines belong to the method that defines it.
    public function apply(callable $f): int
    {
        $wrapped = function (string $s) use ($f): int {
            return $f($s) + 1;
        };

        return $wrapped($this->realm);
    }

    // An anonymous class's method lines fold into the enclosing method too (measured — no separate class element).
    public function withAnon(): string
    {
        $o = new class () {
            public function hello(): string
            {
                return 'hi';
            }
        };

        return $o->hello() . $this->realm;
    }

    public static function helper(int $x): int
    {
        return $x * 2;
    }

    public function logoutUrl(string $redirect): string
    {
        $q = http_build_query(['redirect_uri' => $redirect]);

        return 'https://kc/logout?' . $q;
    }

    /** @return array<string, string> */
    public function __debugInfo(): array
    {
        return ['realm' => $this->realm, 'secret' => '***'];
    }
}
