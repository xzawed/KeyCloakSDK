<?php

declare(strict_types=1);

use Fixture\Keycloak\Admin\AdminClient;
use Fixture\Keycloak\AuthClient;
use PHPUnit\Framework\TestCase;

// Drives part of the fixture so the report has executed, partly executed and never-executed members.
final class DriveIT extends TestCase
{
    public function testDrive(): void
    {
        $a = new AuthClient('demo');
        self::assertSame('demo', $a->realm());
        self::assertSame('ABC', $a->exchange('abc'));
        self::assertSame(5, $a->apply(static fn (string $s): int => strlen($s)));
        self::assertSame('hidemo', $a->withAnon());
        self::assertSame(4, AuthClient::helper(2));
        $admin = new AdminClient('https://kc');
        self::assertSame(['url' => 'https://kc'], $admin->users());
        self::assertSame('***', $admin->masked());
    }
}
