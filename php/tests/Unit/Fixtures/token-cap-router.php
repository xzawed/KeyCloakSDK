<?php

declare(strict_types=1);

/*
 * 토큰 응답 상한(`TokenResponseCapTest`)의 가짜 IdP — `php -S` 라우터다.
 *
 * ⚠️ 왜 Guzzle 핸들러가 아니라 프로세스인가: 상한은 **전송**과 맞물린다(curl 이 싱크에 넘기는 청크·끊기·gzip 디코딩).
 * 가짜 핸들러는 그 길을 건너뛰고, `KeycloakClient::create()`·`AdminClient` 는 Guzzle 을 스스로 만들어 핸들러를 넣을
 * 자리도 없다(`hostile-idp-router.php` 와 같은 이유).
 *
 * 상태는 `TC_STATE` 디렉터리의 `state.json` 이다 — `{"token": 명세, "introspect": 명세}`, 명세는
 * `{"access": 토큰 길이, "size": 본문 총 바이트(0 = 패딩 없음), "framing": "cl"|"close", "gzip": bool, "status": HTTP 상태}`.
 * 본문은 JSON 객체(200 이 아니면 OAuth 오류 응답) 뒤에 JSON 공백을 붙여 `size` 바이트를 맞춘다(gzip 이면 푼 뒤의 바이트).
 * `php -S` 는 청크 인코딩을 쓰지 않는다 — 길이를 모르는
 * 본문은 연결 종료로 끝난다(`close`). 모든 요청은 라우팅 앞에서 `requests.log` 에 `[메서드, 경로, Authorization 길이]` 한 줄로 남는다.
 */

$dir = getenv('TC_STATE');
if (!is_string($dir) || $dir === '') {
    http_response_code(500);

    return;
}
$uri = $_SERVER['REQUEST_URI'] ?? '/';
$path = parse_url(is_string($uri) ? $uri : '/', PHP_URL_PATH);
$path = is_string($path) ? $path : '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
file_put_contents($dir . '/requests.log', json_encode([$method, $path, is_string($auth) ? strlen($auth) : 0], JSON_THROW_ON_ERROR) . "\n", FILE_APPEND | LOCK_EX);

$state = json_decode((string) file_get_contents($dir . '/state.json'), true);
if (!is_array($state)) {
    http_response_code(500);

    return;
}

/** base64url, 패딩 없음. */
$b64 = static fn (string $v): string => rtrim(strtr(base64_encode($v), '+/', '-_'), '=');

/**
 * 정확히 `$len` 바이트인 JWT 모양 토큰 — fschmtt 는 access_token 을 lcobucci 로 파싱하고 exp 로 만료를 본다(서명은 안 본다).
 * 서명 조각은 'A' 만이라 길이가 4n+1 만 아니면 정규 base64url 이다.
 */
$jwt = static function (int $len) use ($b64): string {
    $header = $b64('{"alg":"RS256","typ":"JWT"}');
    for ($k = max(0, intdiv(($len - 64) * 3, 4)); $k >= 0; $k--) {
        $payload = $b64((string) json_encode(['exp' => time() + 300, 'iat' => time(), 'pad' => str_repeat('x', $k)]));
        $sig = $len - strlen($header) - strlen($payload) - 2;
        if ($sig >= 4 && $sig % 4 !== 1) {
            return $header . '.' . $payload . '.' . str_repeat('A', $sig);
        }
    }

    return 'unreachable';
};

/** @param array<mixed> $spec */
$serve = static function (array $spec, string $json): void {
    $status = is_int($spec['status'] ?? null) ? $spec['status'] : 200;
    if ($status !== 200) {
        // 오류 상태의 본문 — OAuth 오류 응답(RFC 6749 §5.2)을 같은 방식으로 부풀린다.
        http_response_code($status);
        $json = '{"error":"invalid_grant","error_description":"tc"}';
    }
    $size = is_int($spec['size'] ?? null) ? $spec['size'] : 0;
    $pad = max(0, $size - strlen($json));
    $gzip = ($spec['gzip'] ?? false) === true;
    header('Content-Type: application/json');
    if ($gzip) {
        header('Content-Encoding: gzip');
    } elseif (($spec['framing'] ?? 'cl') === 'cl') {
        header('Content-Length: ' . (strlen($json) + $pad));
    }
    $ctx = $gzip ? deflate_init(ZLIB_ENCODING_GZIP, ['level' => 9]) : null;
    if ($ctx === false) {
        http_response_code(500);

        return;
    }
    $emit = static function (string $bytes, bool $last) use ($ctx): void {
        echo $ctx === null ? $bytes : deflate_add($ctx, $bytes, $last ? ZLIB_FINISH : ZLIB_NO_FLUSH);
        flush();
    };
    $emit($json, $pad === 0);
    for ($left = $pad; $left > 0;) {
        $n = min($left, 65536);
        $left -= $n;
        $emit(str_repeat(' ', $n), $left === 0);
    }
};

$tokenSuffix = '/protocol/openid-connect/token';
if (str_ends_with($path, $tokenSuffix)) {
    $spec = is_array($state['token'] ?? null) ? $state['token'] : [];
    $access = is_int($spec['access'] ?? null) ? $spec['access'] : 1000;
    $serve($spec, (string) json_encode(['access_token' => $jwt($access), 'token_type' => 'Bearer', 'expires_in' => 300]));
} elseif (str_ends_with($path, $tokenSuffix . '/introspect')) {
    $spec = is_array($state['introspect'] ?? null) ? $state['introspect'] : [];
    $serve($spec, '{"active":true,"sub":"u1","username":"alice","client_id":"c"}');
} elseif ($path === '/admin/serverinfo') {
    // fschmtt 는 첫 자원 접근 전에 서버 버전을 묻는다.
    header('Content-Type: application/json');
    echo '{"systemInfo":{"version":"26.6.0"}}';
} elseif (str_starts_with($path, '/admin/')) {
    header('Content-Type: application/json');
    echo '[]';
} else {
    http_response_code(404);
}
