<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use GuzzleHttp\Promise\Create;
use GuzzleHttp\Promise\PromiseInterface;
use GuzzleHttp\Psr7\FnStream;
use GuzzleHttp\Psr7\Utils;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\StreamInterface;

/**
 * admin 응답 본문을 얼마나 받는가 — 등록부 admin-response-body-unbounded. fschmtt 가 읽지 않는 본문은 받지 않고(GET·HEAD 가 아닌
 * 요청의 2xx — 명령은 응답을 버리고 조회는 GET 뿐이다: `AdminResponseBodyTest` 의 전제 핀), 오류 본문(300 이상)은 토큰 응답 상한에서
 * 자른다 — `AdminClient::raw()` 의 요청도. GET 의 2xx 는 지금처럼 끝까지 받는다(사용자 목록은 정당하게 크다). 토큰 부여는 건드리지
 * 않는다(`TokenResponseCap` 의 몫).
 *
 * curl 은 전송이 끝나야 응답을 넘기므로(본문은 그 전에 싱크로 흘러든다) 전송 **중에** 정한다: `on_headers` 가 최종 응답의 상태를
 * 보고 — GET 이 아닌 2xx 에 본문이 있으면 전송을 끝내고(틀을 알린 본문은 머리에서, 그 밖은 첫 본문 바이트에서), 300 이상이면
 * 본문을 `TokenResponseCap::sink()` 로 받는다(상한 + 1 바이트를 담는 쓰기에서 짧게 답해 curl 은 전송을, 스트림 처리기는 복사를
 * 끝낸다). 그렇게 **스스로** 끝낸 전송의 거부만 머리로 받은 응답에 남긴 본문을 달아 되살린다 — 바깥의 `http_errors` 와
 * `Admin\ErrorTranslation` 이 상태로 고르도록. 그 밖의 거부(전송 실패)는 그대로 넘긴다.
 *
 * ⚠️ curl 은 최종 응답이 아닌 머리에도 `on_headers` 를 부른다 — 중간 응답(`100 Continue` — Guzzle 은 1 MiB 이상인 요청 본문에
 * `Expect` 를 단다)과 프록시 터널의 `200 Connection established`(https 대상에 `HTTPS_PROXY`). 그것을 쓰기의 응답으로 보고 끊으면
 * 요청은 서버에 닿지 않은 채 성공으로 돌아온다(실측 — 둘 다 고치기 전 판이 그랬다). 그래서 1xx 는 건너뛰고(규격을 어겨 틀을 단
 * 것도), CONNECT 의 머리는 curl 이 넘기지 않게 한다(`CURLOPT_SUPPRESS_CONNECT_HEADERS`) — 규격(RFC 9110 §9.3.6)을 어기고 그 200 에
 * 틀을 다는 프록시가 있어 틀로는 가를 수 없다(Grok 레그 2 지목 — 그 앞의 판은 터널 너머 PUT 을 보내지도 않고 200 을 성공으로
 * 돌려줬다). 스트림 처리기에서는 PHP 의 http 래퍼가 CONNECT 의 머리를 읽고 버린다(php-src `ext/standard/http_fopen_wrapper.c`).
 * 틀(`framed`)이 없는 2xx 는 머리에서 끊지 않는다 —
 * 본문 바이트가 오면 첫 바이트에서 끊는다(그래서 틀이 없는 204 는 연결을 잃지 않는다).
 * ⚠️ 본문이 없는 2xx(Keycloak 의 쓰기 응답 — 틀이 없는 204 · `Content-Length: 0` 인 201)는 머리에서 끊지 않는다 — 끊을 것이
 * 없고, 끊으면 curl 이 다음 요청에 쓸 연결만 잃는다.
 * ⚠️ 싱크에서 예외를 던지지 않는다 — curl 은 그 예외에도 본문을 끝까지 받았다(실측). 스트림 처리기가 싱크의 짧은 쓰기(상한 · 첫
 * 바이트 거부)에 복사를 멈추는 것은 guzzlehttp/psr7 2.11 이상이다(짧은 쓰기를 다시 쓰는 `copyToStream`) — 그 아래 판은 Content-Length
 * 를 알린 본문을 끝까지 읽고 쥐는 양만 상한이다.
 *
 * @internal
 */
final class AdminResponseBody
{
    /**
     * admin 핸들러 스택 미들웨어 — `$isTokenRequest` 가 고르는 요청(fschmtt 의 토큰 부여)은 그대로 보낸다.
     *
     * @param \Closure(RequestInterface): bool $isTokenRequest
     * @return \Closure(callable(RequestInterface, array<string, mixed>): PromiseInterface): (\Closure(RequestInterface, array<string, mixed>): PromiseInterface)
     */
    public static function middleware(\Closure $isTokenRequest): \Closure
    {
        return static fn (callable $handler): \Closure => static function (RequestInterface $request, array $options) use ($handler, $isTokenRequest): PromiseInterface {
            if ($isTokenRequest($request)) {
                return self::promise($handler($request, $options));
            }
            if (\defined('CURLOPT_SUPPRESS_CONNECT_HEADERS')) {   // ext-curl 이 없으면 스트림 처리기 — CONNECT 머리를 넘기지 않는다
                $curl = \is_array($options['curl'] ?? null) ? $options['curl'] : [];
                $options['curl'] = $curl + [\CURLOPT_SUPPRESS_CONNECT_HEADERS => true];   // 프록시 CONNECT 의 머리 — 클래스 docblock
            }
            $head = null;     // 최종 응답의 머리
            $error = false;   // 300 이상 — 본문을 상한에서 자른다
            $unread = false;  // fschmtt 가 읽지 않는 2xx 본문 — 받지 않는다
            $cut = false;     // 이 미들웨어가 2xx 의 전송을 끊었다 — 그 거부만 머리로 되살린다
            // 2xx 본문을 받는 요청 — fschmtt 의 조회(GET)와, 본문이 없는 HEAD(RFC 9110 §9.3.2 — `raw()->resource()` 의 명령이 보낸다).
            $reads = \in_array($request->getMethod(), ['GET', 'HEAD'], true);
            $options['on_headers'] = static function (ResponseInterface $response) use (&$head, &$error, &$unread, &$cut, $reads): void {
                if ($response->getStatusCode() < 200) {
                    return;   // 중간 응답 — 클래스 docblock
                }
                $head = $response;
                $error = $response->getStatusCode() >= 300;
                // 본문 없다는 2xx 도 싱크는 바이트를 받지 않는다 — 스트림 처리기는 `Content-Length: 0` 을 길이 미상으로 보고 EOF 까지
                // 복사한다(Guzzle `StreamHandler::drain`). 머리에서 끊는 것은 틀을 알린 본문뿐이다.
                $unread = !$error && !$reads;
                if ($unread && !self::bodiless($response) && self::framed($response)) {
                    $cut = true;
                    throw new \RuntimeException('admin response body left unread');   // 본문 전에 전송을 끝낸다
                }
            };
            $plain = Utils::streamFor(Utils::tryFopen('php://temp', 'r+'));   // Guzzle 의 기본 싱크와 같다
            $capped = TokenResponseCap::sink();
            $options['sink'] = FnStream::decorate($plain, [
                // ⚠️ 화살표 함수로 바꾸지 말 것 — 그것은 `$error`·`$unread` 를 만들 때의 값(거짓)으로 잡는다.
                'write' => static function (string $data) use (&$error, &$unread, &$cut, $capped, $plain): int {
                    if ($unread) {
                        $cut = true;
                        return 0;   // GET·HEAD 가 아닌 요청의 2xx 본문 바이트(틀이 없는 본문 · 본문 없다는 응답 뒤) — 받지 않고 끝낸다
                    }

                    return $error ? $capped->write($data) : $plain->write($data);
                },
            ]);

            return self::promise($handler($request, $options))->then(
                static function (ResponseInterface $response) use (&$error, $capped): ResponseInterface {
                    return $error ? $response->withBody(self::kept($capped)) : $response;
                },
                static function (mixed $reason) use (&$head, &$error, &$cut, $capped): ResponseInterface|PromiseInterface {
                    if ($head instanceof ResponseInterface && $cut) {
                        return $head->withBody(Utils::streamFor(''));
                    }
                    if ($head instanceof ResponseInterface && $error && TokenResponseCap::overflowed($capped)) {
                        return $head->withBody(self::kept($capped));   // 싱크의 짧은 쓰기에 curl 이 끊은 전송
                    }

                    return Create::rejectionFor($reason);
                },
            );
        };
    }

    /**
     * 본문이 없다고 머리가 말하는 응답 — `Content-Length: 0`. 204 는 따로 가르지 않는다: 규격대로면 204 에는 틀이 없어(`framed`)
     * 머리에서 끊기지 않고, 규격을 어겨 길이를 단 204 는 끊어도 결과가 같다(실측: 어느 쪽이든 다음 요청은 새 연결로 간다).
     */
    private static function bodiless(ResponseInterface $response): bool
    {
        return $response->getHeaderLine('Content-Length') === '0';
    }

    /**
     * 본문의 틀을 머리가 알리는 응답 — 본문이 온다고 알렸으니 머리에서 끊는다. 규격대로인 204 에는 틀이 없다(RFC 9110 §8.6 —
     * Keycloak 26.6 의 쓰기 204 도 그렇다). Guzzle 은 압축을 풀 때 Content-Length 를 `X-Encoded-Content-Length` 로 옮긴다.
     * ⚠️ PHP 의 http 래퍼(스트림 처리기)는 청크를 풀며 `Transfer-Encoding` 을 머리에 남기지 않는다 — 그 응답은 여기서 틀이 없다고
     * 보여 첫 본문 바이트에서 끊는다(`AdminResponseBodyTest::headStallRows`).
     */
    private static function framed(ResponseInterface $response): bool
    {
        return $response->hasHeader('Content-Length') || $response->hasHeader('Transfer-Encoding') || $response->hasHeader('X-Encoded-Content-Length');
    }

    /** 오류 본문에서 남기는 것 — 상한 싱크의 앞 `TOKEN_RESPONSE_MAX_BYTES` 바이트. */
    private static function kept(StreamInterface $capped): StreamInterface
    {
        $capped->rewind();

        return Utils::streamFor(substr($capped->getContents(), 0, TokenResponseCap::TOKEN_RESPONSE_MAX_BYTES));
    }

    /** `TokenResponseCap::promise` 와 같은 정규화 — 핸들러의 반환을 약속으로 세운다. */
    private static function promise(mixed $result): PromiseInterface
    {
        return $result instanceof PromiseInterface ? $result : Create::promiseFor($result);
    }
}
