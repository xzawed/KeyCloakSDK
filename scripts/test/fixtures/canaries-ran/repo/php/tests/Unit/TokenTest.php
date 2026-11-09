<?php

declare(strict_types=1);

namespace X\Tests\Unit;

final class TokenTest extends TestCase
{
    public function testRejectsMismatchedNonce(): void
    {
    }

    #[DataProvider('bad')]
    public function testNonStringAccessTokenIsRejected(mixed $bad): void
    {
    }
}
