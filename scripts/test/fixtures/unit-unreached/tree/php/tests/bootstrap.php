<?php

declare(strict_types=1);

// PHPUnit from the lane's vendor/ (copied in when the data is regenerated — see scripts/test/test-unit-unreached.sh), then the fixture
// classes by file name: `Fixture\Unit\AuthClient` is src/AuthClient.php.
require __DIR__ . '/../vendor/autoload.php';

spl_autoload_register(static function (string $class): void {
    $file = __DIR__ . '/../src/' . substr($class, strrpos($class, '\\') + 1) . '.php';
    if (str_starts_with($class, 'Fixture\\Unit\\') && is_file($file)) {
        require $file;
    }
});
