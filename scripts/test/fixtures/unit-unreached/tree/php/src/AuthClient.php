<?php

declare(strict_types=1);

namespace Fixture\Unit;

/**
 * Fixture boundary class for the unit-unreached ledger — the unit drive (tests/Unit/DriveTest.php) reaches part of it.
 */
final class AuthClient
{
    public function __construct(private readonly string $realm)
    {
    }

    // Fully reached by the drive — not in the ledger.
    public function realm(): string
    {
        return $this->realm;
    }

    // A failure branch on its own line: the drive never sends an empty code.
    public function exchange(string $code): string
    {
        if ($code === '') {
            throw new \InvalidArgumentException('empty code');
        }

        return strtoupper($code);
    }

    // A closure's lines belong to the method that defines it: the drive never passes an empty string through it.
    public function apply(callable $f): int
    {
        $wrapped = function (string $s) use ($f): int {
            if ($s === '') {
                return 0;
            }

            return $f($s);
        };

        return $wrapped($this->realm);
    }

    // A failure branch on a line the happy path already runs — line counts cannot see it (the ledger's known gap).
    public function pick(?string $v): string
    {
        return $v ?? throw new \LogicException('none');
    }

    // Never called by the drive.
    public function logoutUrl(string $redirect): string
    {
        return 'https://kc/logout?' . http_build_query(['redirect_uri' => $redirect]);
    }
}
