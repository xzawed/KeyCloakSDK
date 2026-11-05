<?php

declare(strict_types=1);

use PHPUnit\Framework\TestCase;

// Touches no boundary code — the data of this run alone must read as "executed 0 lines" (a measurement failure).
final class ZeroIT extends TestCase
{
    public function testNothing(): void
    {
        self::assertSame(2, 1 + 1);
    }
}
