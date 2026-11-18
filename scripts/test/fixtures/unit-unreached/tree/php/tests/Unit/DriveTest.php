<?php

declare(strict_types=1);

use Fixture\Unit\AuthClient;
use Fixture\Unit\Config;
use PHPUnit\Framework\TestCase;

// Drives part of the boundary — never an empty code, never an empty string through apply's closure, never a null pick,
// never logoutUrl.
final class DriveTest extends TestCase
{
    public function testDrive(): void
    {
        $a = new AuthClient('demo');
        self::assertSame('demo', $a->realm());
        self::assertSame('ABC', $a->exchange('abc'));
        self::assertSame(4, $a->apply(static fn (string $s): int => strlen($s)));
        self::assertSame('x', $a->pick('x'));
        self::assertTrue((new Config('demo'))->valid());
    }
}
