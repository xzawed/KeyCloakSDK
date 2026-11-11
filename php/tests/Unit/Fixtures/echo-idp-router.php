<?php

declare(strict_types=1);

/*
 * The echo IdP of `OAuthErrorCodeEchoTest` — a `php -S` router (the SDK builds its own Guzzle clients, so there is no
 * handler to inject; `bearer-idp-router.php` has the same reason).
 *
 * State is `state.json` in the `EI_STATE` directory: `{"fixed": <any JSON value>}` answers that value as `error`, and
 * `{"echo": "<form field>", "form": "whole|truncated|extended"}` answers what THIS request sent in that field — the
 * client secret from Basic (each part form-url-encoded) or from the form. Every token POST answers 400
 * `application/json` `{"error": …}` and is logged to `requests.log` as `[path, sent form fields]`. fschmtt asks
 * `/admin/serverinfo` before its first resource call — that is where its grant happens.
 */

$dir = getenv('EI_STATE');
if (!is_string($dir) || $dir === '') {
    http_response_code(500);

    return;
}
$uri = $_SERVER['REQUEST_URI'] ?? '/';
$path = parse_url(is_string($uri) ? $uri : '/', PHP_URL_PATH);
$path = is_string($path) ? $path : '/';

if (!str_ends_with($path, '/protocol/openid-connect/token')) {
    if ($path === '/admin/serverinfo') {
        header('Content-Type: application/json');
        echo '{"systemInfo":{"version":"26.6.0"}}';

        return;
    }
    http_response_code(404);

    return;
}

parse_str((string) file_get_contents('php://input'), $sent);
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
if (is_string($auth) && str_starts_with($auth, 'Basic ')) {
    $pair = explode(':', (string) base64_decode(substr($auth, 6), true), 2);
    $sent['client_secret'] = urldecode($pair[1] ?? '');
}
file_put_contents($dir . '/requests.log', json_encode([$path, $sent], JSON_THROW_ON_ERROR) . "\n", FILE_APPEND | LOCK_EX);

$state = json_decode((string) file_get_contents($dir . '/state.json'), true);
$state = is_array($state) ? $state : [];
if (array_key_exists('fixed', $state)) {
    $error = $state['fixed'];
} else {
    $value = $sent[is_string($state['echo'] ?? null) ? $state['echo'] : ''] ?? '';
    $value = is_string($value) ? $value : '';
    $error = match ($state['form'] ?? 'whole') {
        'truncated' => substr($value, 0, 11),
        'extended' => $value . '_x',
        default => $value,
    };
}
http_response_code(400);
header('Content-Type: application/json');
echo json_encode(['error' => $error], JSON_THROW_ON_ERROR);
