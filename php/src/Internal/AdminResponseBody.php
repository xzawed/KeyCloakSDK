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
 * admin 응답 본문을 얼마나 받는가 — 등록부 admin-response-body-unbounded. fschmtt 가 읽지 않는 본문은 받지 않고(GET 이 아닌 요청의
 * 2xx — 명령은 응답을 버리고 조회는 GET 뿐이다: `AdminResponseBodyTest` 의 전제 핀), 오류 본문(300 이상)은 토큰 응답 상한에서
 * 자른다 — `AdminClient::raw()` 의 요청도. GET 의 2xx 는 지금처럼 끝까지 받는다(사용자 목록은 정당하게 크다). 토큰 부여는 건드리지
 * 않는다(`TokenResponseCap` 의 몫).
 *
 * curl 은 전송이 끝나야 응답을 넘기므로(본문은 그 전에 싱크로 흘러든다) 전송 **중에** 정한다: `on_headers` 가 최종 응답의 상태를
 * 보고 — GET 이 아닌 2xx 에 본문이 있으면 거기서 전송을 끝내고, 300 이상이면 본문을 `TokenResponseCap::sink()` 로 받는다(상한 + 1
 * 바이트를 담는 쓰기에서 짧게 답해 curl 은 전송을, 스트림 처리기는 복사를 끝낸다). 그렇게 끝난 전송의 거부는 머리로 받은 응답에
 * 남긴 본문을 달아 되살린다 — 바깥의 `http_errors` 와 `Admin\ErrorTranslation` 이 상태로 고르도록.
 *
 * ⚠️ curl 은 중간 응답(`100 Continue` — Guzzle 은 1 MiB 이상인 요청 본문에 `Expect` 를 단다)에도 `on_headers` 를 부른다. 그것을 최종
 * 응답으로 보면 요청 본문을 보내기도 전에 끝내고 쓰기가 성공한 듯 돌아온다 — 2xx 이상만 본다.
 * ⚠️ 본문이 없다고 머리가 말하는 2xx(204 · `Content-Length: 0` — Keycloak 의 쓰기 응답)는 끊지 않는다 — 끊을 것이 없고, 끊으면
 * curl 이 다음 요청에 쓸 연결만 잃는다.
 * ⚠️ 싱크에서 예외를 던지지 않는다 — curl 은 그 예외에도 본문을 끝까지 받았다(실측). 스트림 처리기가 상한에서 읽기를 멈추는 것은
 * guzzlehttp/psr7 2.11 이상이다(짧은 쓰기를 다시 쓰는 `copyToStream`) — 그 아래 판은 쥐는 양만 상한이다.
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
            $head = null;     // 최종 응답의 머리
            $error = false;   // 300 이상 — 본문을 상한에서 자른다
            $unread = false;  // fschmtt 가 읽지 않는 2xx 본문 — 머리에서 끊었다
            $reads = $request->getMethod() === 'GET';
            $options['on_headers'] = static function (ResponseInterface $response) use (&$head, &$error, &$unread, $reads): void {
                if ($response->getStatusCode() < 200) {
                    return;   // 중간 응답 — 클래스 docblock
                }
                $head = $response;
                $error = $response->getStatusCode() >= 300;
                if (!$error && !$reads && !self::bodiless($response)) {
                    $unread = true;
                    throw new \RuntimeException('admin response body left unread');   // 본문 전에 전송을 끝낸다
                }
            };
            $plain = Utils::streamFor(Utils::tryFopen('php://temp', 'r+'));   // Guzzle 의 기본 싱크와 같다
            $capped = TokenResponseCap::sink();
            $options['sink'] = FnStream::decorate($plain, [
                // ⚠️ 화살표 함수로 바꾸지 말 것 — 그것은 `$error` 를 만들 때의 값(거짓)으로 잡는다.
                'write' => static function (string $data) use (&$error, $capped, $plain): int {
                    return $error ? $capped->write($data) : $plain->write($data);
                },
            ]);

            return self::promise($handler($request, $options))->then(
                static function (ResponseInterface $response) use (&$error, $capped): ResponseInterface {
                    return $error ? $response->withBody(self::kept($capped)) : $response;
                },
                static function (mixed $reason) use (&$head, &$error, &$unread, $capped): ResponseInterface|PromiseInterface {
                    if ($head instanceof ResponseInterface && $unread) {
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

    /** 본문이 없다고 머리가 말하는 응답. */
    private static function bodiless(ResponseInterface $response): bool
    {
        return $response->getStatusCode() === 204 || $response->getHeaderLine('Content-Length') === '0';
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
