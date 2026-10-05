/**
 * `token-response-cap.ts` 의 읽기 자체 — 공개 API 로 잰 레인별 계약은 `token-response-cap.test.ts` 에 있다. 여기서는
 * 그 파일이 닿지 않는 갈래(기본 스트림 본문 · 본문 없는 응답 · 200~599 밖 상태 · 신호 찾기)와 할당의 크기를 잰다.
 */
import { readFileSync } from 'node:fs'
import { createServer as createTcpServer, type Server as TcpServer } from 'node:net'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import {
  fetchTokenEndpointBounded,
  readCapped,
  ResponseTooLargeError,
  responseTooLarge,
  TOKEN_RESPONSE_MAX_BYTES,
} from '../../src/token-response-cap.js'

afterEach(() => {
  vi.restoreAllMocks()
})

describe('상한 상수', () => {
  it('1,048,576 이고 소스에 맨 십진 리터럴로 한 번 적혀 있다(교차 언어 가드가 뽑는다)', () => {
    expect(TOKEN_RESPONSE_MAX_BYTES).toBe(1_048_576)
    const source = readFileSync(new URL('../../src/token-response-cap.ts', import.meta.url), 'utf8')
    const declarations = source.match(/export const TOKEN_RESPONSE_MAX_BYTES = (\S+)\n/g) ?? []
    expect(declarations).toEqual(['export const TOKEN_RESPONSE_MAX_BYTES = 1_048_576\n'])
  })
})

const bytes = (n: number, fill = 0x20): Uint8Array => new Uint8Array(n).fill(fill)
const byteStream = (n: number): ReadableStream<Uint8Array> => new Response(bytes(n)).body!

/** 기본(바이트가 아닌) 스트림 — `chunk` 바이트씩 `n` 바이트를 낸다. 취소되면 `cancelled` 가 참이 된다. */
function defaultStream(
  n: number,
  chunk: number,
): { stream: ReadableStream<Uint8Array>; cancelled: () => boolean } {
  let left = n
  let cancelled = false
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (left === 0) return controller.close()
      const size = Math.min(chunk, left)
      left -= size
      controller.enqueue(bytes(size))
    },
    cancel() {
      cancelled = true
    },
  })
  return { stream, cancelled: () => cancelled }
}

describe('readCapped — BYOB(바이트 스트림)', () => {
  it('정확히 cap 바이트는 그대로 돌려주고 cap+1 바이트는 ResponseTooLargeError', async () => {
    await expect(readCapped(byteStream(1000), 1000)).resolves.toHaveLength(1000)
    await expect(readCapped(byteStream(1001), 1000)).rejects.toBeInstanceOf(ResponseTooLargeError)
    await expect(readCapped(byteStream(0), 1000)).resolves.toHaveLength(0)
  })

  it('받은 바이트는 그대로다 — 여러 번 읽어 이어 붙여도', async () => {
    const source = new Uint8Array(50_000).map((_, i) => i % 251)
    const out = await readCapped(new Response(source).body!, 60_000)
    expect(Buffer.from(out).equals(Buffer.from(source))).toBe(true)
  })

  /** 계약 (3): 메모리는 읽은 만큼만 — ~2 KiB 응답을 판정하는 데 상한 근처를 잡지 않는다. */
  it('~2 KiB 본문은 상한 크기 버퍼를 잡지 않는다 — 청한 버퍼와 돌려준 버퍼 모두 16 KiB 이하', async () => {
    const capacities: number[] = []
    const read = ReadableStreamBYOBReader.prototype.read
    vi.spyOn(ReadableStreamBYOBReader.prototype, 'read').mockImplementation(function (
      this: ReadableStreamBYOBReader,
      view: ArrayBufferView,
      ...rest: unknown[]
    ) {
      capacities.push(view.buffer.byteLength)
      return (read as (...a: unknown[]) => Promise<unknown>).call(this, view, ...rest)
    } as never)
    const out = await readCapped(byteStream(2048), TOKEN_RESPONSE_MAX_BYTES)
    expect(out).toHaveLength(2048)
    expect(capacities.length).toBeGreaterThan(0)
    expect(Math.max(...capacities)).toBeLessThanOrEqual(16_384)
    expect(out.buffer.byteLength).toBeLessThanOrEqual(16_384)
  })
})

describe('readCapped — 기본 스트림(바이트 스트림이 아닌 본문)', () => {
  it('상한 안이면 이어 붙여 돌려준다', async () => {
    const { stream } = defaultStream(10_000, 3000)
    await expect(readCapped(stream, 10_000)).resolves.toHaveLength(10_000)
  })

  it('상한을 넘기는 조각에서 멈추고 스트림을 취소한다 — 그 조각은 쌓지 않는다', async () => {
    const { stream, cancelled } = defaultStream(10_000, 3000)
    await expect(readCapped(stream, 5000)).rejects.toBeInstanceOf(ResponseTooLargeError)
    expect(cancelled()).toBe(true)
  })
})

describe('readCapped — 취소가 실패해도 상한 신호가 이긴다', () => {
  // 취소는 원천의 cancel 이 던지면 거부된다 — 그 거부가 상한 신호를 덮으면 경계가 정확한 메시지를 못 만든다.
  const cancelFails = (): never => {
    throw new Error('cancel failed')
  }

  it('바이트 스트림(BYOB)', async () => {
    const stream = new ReadableStream({
      type: 'bytes',
      pull(controller: ReadableByteStreamController) {
        controller.enqueue(bytes(4096))
      },
      cancel: cancelFails,
    }) as ReadableStream<Uint8Array>
    await expect(readCapped(stream, 5000)).rejects.toBeInstanceOf(ResponseTooLargeError)
  })

  it('기본 스트림', async () => {
    const stream = new ReadableStream<Uint8Array>({
      pull(controller: ReadableStreamDefaultController<Uint8Array>) {
        controller.enqueue(bytes(4096))
      },
      cancel: cancelFails,
    })
    await expect(readCapped(stream, 5000)).rejects.toBeInstanceOf(ResponseTooLargeError)
  })
})

describe('fetchTokenEndpointBounded', () => {
  let http: Server
  let origin = ''
  let tcp: TcpServer
  let tcpOrigin = ''

  beforeAll(async () => {
    http = createServer((req, res) => {
      if (req.url === '/no-content') {
        res.writeHead(204).end()
        return
      }
      res.writeHead(418, 'Teapot Here', { 'content-type': 'application/json', 'x-probe': 'kept' })
      res.end('{"error":"x"}')
    })
    await new Promise<void>((resolve) => http.listen(0, '127.0.0.1', resolve))
    origin = `http://127.0.0.1:${(http.address() as AddressInfo).port}`
    // `Response` 생성자는 200~599 밖 상태를 거부하지만 undici 는 그대로 넘긴다 — 날 HTTP 로 만든다.
    tcp = createTcpServer((socket) => {
      socket.on('data', () => {
        socket.end(
          'HTTP/1.1 999 Weird\r\ncontent-type: application/json\r\ncontent-length: 7\r\n' +
            'connection: close\r\n\r\n{"a":1}',
        )
      })
    })
    await new Promise<void>((resolve) => tcp.listen(0, '127.0.0.1', resolve))
    tcpOrigin = `http://127.0.0.1:${(tcp.address() as AddressInfo).port}`
  })

  afterAll(async () => {
    http.closeAllConnections()
    await new Promise<void>((resolve) => http.close(() => resolve()))
    await new Promise<void>((resolve) => tcp.close(() => resolve()))
  })

  it('다시 만든 응답은 상태·상태 문구·헤더·본문을 지킨다', async () => {
    const res = await fetchTokenEndpointBounded(`${origin}/x`, { method: 'POST', body: 'a=b' })
    expect([res.status, res.statusText, res.headers.get('x-probe')]).toEqual([
      418,
      'Teapot Here',
      'kept',
    ])
    expect(await res.json()).toEqual({ error: 'x' })
  })

  it('본문이 없는 응답(204)은 그대로 돌려준다', async () => {
    const res = await fetchTokenEndpointBounded(`${origin}/no-content`)
    expect([res.status, res.body]).toEqual([204, null])
  })

  it('200~599 밖 상태는 다시 만들 수 없으니 읽지 않고 그대로 돌려준다', async () => {
    const res = await fetchTokenEndpointBounded(tcpOrigin)
    expect(res.status).toBe(999)
    expect(res.bodyUsed).toBe(false)
    await res.body?.cancel()
  })
})

describe('responseTooLarge — 원인 사슬에서 신호를 찾는다', () => {
  it('감싼 오류의 사슬 안에서 찾고, 없으면 undefined', () => {
    const signal = new ResponseTooLargeError(10)
    const wrapped = new Error('something went wrong', {
      cause: new Error('mid', { cause: signal }),
    })
    expect(responseTooLarge(wrapped)).toBe(signal)
    expect(responseTooLarge(signal)?.message).toBe('response body exceeds 10 bytes')
    expect(responseTooLarge(new Error('plain'))).toBeUndefined()
    expect(responseTooLarge('not an error')).toBeUndefined()
  })

  it('사슬은 여덟 단계까지만 본다 — 순환하는 cause 에서 멈춘다', () => {
    const loop = new Error('loop') as Error & { cause?: unknown }
    loop.cause = loop
    expect(responseTooLarge(loop)).toBeUndefined()
  })
})
