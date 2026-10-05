<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

/**
 * 토큰·introspection 응답 본문이 상한(`TokenResponseCap::TOKEN_RESPONSE_MAX_BYTES`)을 넘었다 — 하위 라이브러리(league·fschmtt)의
 * 호출 스택 **안에서** 난 판정을 SDK 경계까지 나르는 운반체다. @internal
 *
 * ⚠️ 공개 API 로 나가지 않는다 — `AuthClient::getAccessToken` 과 `Admin\ErrorTranslation::call` 이 이것을 받아 **새**
 * `KeycloakTransportError`(같은 메시지, 원인 없음)로 바꾼다. 이 예외의 트레이스는 league 의 `getAccessToken($grant, $options)`
 * (refresh_token·code)와 Guzzle 의 `request(…, ['form_params' => [… client_secret]])` 프레임 인자를 쥐므로 원인으로 달면 안 된다.
 * `\UnexpectedValueException` 을 잇는 것은 league 가 `getAccessToken()` 에 선언한 예외라서다(그 경계의 catch 가 죽은 갈래가 아니다).
 */
final class ResponseTooLarge extends \UnexpectedValueException
{
    /** @param string $what 넘은 본문의 이름 — `token response` · `admin token response` */
    public function __construct(string $what)
    {
        parent::__construct(sprintf('%s exceeds %d bytes', $what, TokenResponseCap::TOKEN_RESPONSE_MAX_BYTES));
    }
}
