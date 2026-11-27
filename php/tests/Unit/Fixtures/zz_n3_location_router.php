<?php

declare(strict_types=1);

/*
 * measurement only — not for merge (task n3). The `php -S` router of `zz_n3_location_measureTest`: the token grant gets a
 * token, fschmtt's `/admin/serverinfo` a version, and `POST /admin/realms/it-realm/users` a 201 whose Location value is the
 * raw bytes hex-encoded in `N3_DIR/location.hex`. Every request is logged to `N3_DIR/requests.log` as `METHOD path`.
 */

$dir = (string) getenv('N3_DIR');
$uri = $_SERVER['REQUEST_URI'] ?? '/';
$path = parse_url(is_string($uri) ? $uri : '/', PHP_URL_PATH);
$path = is_string($path) ? $path : '/';
$method = $_SERVER['REQUEST_METHOD'] ?? '?';
file_get_contents('php://input');
file_put_contents($dir . '/requests.log', "$method $path\n", FILE_APPEND | LOCK_EX);

if (str_ends_with($path, '/protocol/openid-connect/token')) {
    // fschmtt reads the access token as a JWT (its exp) — an unsigned-looking dummy one, as admin-body-server.php mints.
    $b64 = static fn (string $s): string => rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
    $jwt = $b64('{"alg":"RS256","typ":"JWT"}') . '.' . $b64((string) json_encode(['exp' => time() + 300, 'iat' => time(), 'sub' => 'svc']))
        . '.' . str_repeat('A', 43);
    header('Content-Type: application/json');
    echo json_encode(['access_token' => $jwt, 'token_type' => 'Bearer', 'expires_in' => 300]);

    return;
}
if ($path === '/admin/serverinfo') {
    header('Content-Type: application/json');
    echo '{"systemInfo":{"version":"26.6.0"}}';

    return;
}
if ($method === 'POST' && rtrim($path, '/') === '/admin/realms/it-realm/users') {
    http_response_code(201);   // first — header('Location') keeps a 201 already set
    header('Location: ' . (string) hex2bin(trim((string) file_get_contents($dir . '/location.hex'))));

    return;
}
http_response_code(404);
