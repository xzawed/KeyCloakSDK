# Keycloak 서버 배포 가이드 — 단일 VM + Docker Compose (프로덕션)

> **이 문서는 이 SDK가 아니라 Keycloak *서버*를 세우는 방법입니다.** 이 SDK(`keycloak-sdk`)는 **클라이언트 라이브러리**일 뿐, Keycloak 서버를 포함하지 않습니다. Keycloak은 Red Hat이 만든 **완제품 오픈소스 서버**이며, 우리가 서버를 *구현*하는 게 아니라 **가져다 실행(배포)** 합니다(PostgreSQL·nginx를 코딩하지 않고 실행만 하는 것과 같음). 개념 정리는 [getting-started](getting-started.md) 참고.

**대상**: 한 대의 VM(클라우드 인스턴스 또는 온프레미스 서버)에 프로덕션급 Keycloak을 세우려는 운영자. 중소규모·단일 노드에 적합하다(HA·오토스케일이 필요하면 Kubernetes+Operator 방식을 별도로).

**버전 기준**: Keycloak **26.x**(이 SDK는 26.6.x 검증). 설정 키는 공식 26.x 문서 기준이다.

```
인터넷 ──443──▶ Caddy (TLS 종단, Let's Encrypt 자동)
                  │ 내부 HTTP(8080)
                  ▼
              Keycloak 26.x ──JDBC──▶ PostgreSQL (영속 볼륨)
              (start --optimized · http-enabled · proxy-headers)
```

---

## 0. 사전 준비

- **VM**: 2 vCPU / 4GB RAM 이상, Docker + Docker Compose(v2) 설치.
- **도메인**: `auth.example.com` A 레코드 → VM 공인 IP.
- **방화벽**: **80/443만 개방**. `5432`(DB)·`8080`(KC HTTP)·`9000`(관리/health)은 외부 비공개.
- **왜 외부 DB인가**: 개발용 `start-dev`는 내장 H2를 쓰지만, 운영에서는 데이터 유실·마이그레이션 문제로 **금지**한다. 반드시 PostgreSQL 등 외부 DB를 쓴다.

## 1. 디렉터리 & 시크릿

```
keycloak-deploy/
├─ .env                # 시크릿 (git 커밋 금지, chmod 600)
├─ docker-compose.yml
├─ Dockerfile          # Keycloak 최적화 이미지
└─ Caddyfile
```

**`.env`** — 강한 랜덤값으로 생성(`openssl rand -base64 32`):

```dotenv
KC_DB_PASSWORD=<강한-랜덤-DB-비밀번호>
KC_BOOTSTRAP_ADMIN_PASSWORD=<강한-랜덤-임시-관리자-비밀번호>
KC_HOSTNAME=https://auth.example.com
ACME_EMAIL=you@example.com
```

## 2. Keycloak 최적화 이미지 (`Dockerfile`)

빌드타임 옵션(`KC_DB`·health·metrics)을 미리 구운 **optimized 이미지**를 만들면 기동이 빨라지고 `start --optimized`를 쓸 수 있다:

```dockerfile
FROM quay.io/keycloak/keycloak:26.6 AS builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.6
COPY --from=builder /opt/keycloak/ /opt/keycloak/
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

> ⚠️ 이미지 태그는 **patch 버전까지 고정**하고, 이 SDK가 검증한 버전(26.6.x)에 맞춘다. `KC_HEALTH_ENABLED`/`KC_METRICS_ENABLED`/`KC_DB`는 **빌드타임** 옵션이라 이미지에 굽는다.

## 3. `docker-compose.yml`

```yaml
services:
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${KC_DB_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak -d keycloak"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [internal]
    # 외부 포트 노출 안 함 (내부 네트워크 전용)

  keycloak:
    build: .
    restart: unless-stopped
    command: start --optimized
    environment:
      # DB (런타임 옵션)
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KC_DB_PASSWORD}
      # hostname v2 — 전체 공개 URL
      KC_HOSTNAME: ${KC_HOSTNAME}
      KC_HOSTNAME_STRICT: "true"
      # 리버스 프록시(Caddy)가 TLS 종단 → 내부는 HTTP + 프록시 헤더 신뢰
      KC_HTTP_ENABLED: "true"
      KC_PROXY_HEADERS: xforwarded
      # 최초 부트스트랩 관리자 (첫 로그인 후 즉시 교체·제거)
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KC_BOOTSTRAP_ADMIN_PASSWORD}
      # 구조화 로그(선택)
      KC_LOG_CONSOLE_OUTPUT: json
    depends_on:
      postgres: { condition: service_healthy }
    healthcheck:
      # 공식 KC 이미지에는 curl이 없어 bash /dev/tcp로 관리포트(9000) readiness 확인
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/127.0.0.1/9000; echo -e 'GET /health/ready HTTP/1.1\\r\\nhost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n' >&3; cat <&3 | grep -m1 -q 'UP'"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 90s
    networks: [internal]

  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on: [keycloak]
    networks: [internal]

volumes:
  pgdata:
  caddy_data:
  caddy_config:

networks:
  internal:
```

## 4. `Caddyfile` (자동 HTTPS)

```
auth.example.com {
    reverse_proxy keycloak:8080
    encode gzip
}
```

> Caddy가 Let's Encrypt로 인증서를 **자동 발급·갱신**한다(80/443 개방 필요). nginx/Traefik를 쓰려면 인증서 관리 + `X-Forwarded-*` 헤더 전달을 직접 설정한다.

## 5. 기동 & 최초 부트스트랩

```bash
docker compose up -d --build
docker compose logs -f keycloak          # "Running the server in production mode" / "started" 확인
```

1. `https://auth.example.com` 관리 콘솔 → `admin` / (`.env`의 임시 비밀번호)로 로그인.
2. **realm 생성**(예: `myapp`) → **client 등록**(confidential, *Service accounts roles* on → `clientId`/`clientSecret` 확보) → 사용자 생성.
3. **부트스트랩 관리자 교체**: master realm에 개인 관리자 계정을 신설 → 임시 `admin` 계정 삭제 → compose에서 `KC_BOOTSTRAP_ADMIN_*` 제거(최초 1회용).

## 6. 프로덕션 필수 체크리스트

| 항목 | 조치 |
|---|---|
| **TLS** | Caddy 자동 HTTPS(또는 프록시 인증서). Keycloak 직접 HTTPS면 `KC_HTTPS_CERTIFICATE_FILE`/`KC_HTTPS_CERTIFICATE_KEY_FILE`(PEM). |
| **hostname** | `KC_HOSTNAME`=전체 공개 URL + `KC_HOSTNAME_STRICT=true`. |
| **프록시 헤더** | `KC_PROXY_HEADERS=xforwarded` + 프록시가 `X-Forwarded-*`를 **덮어쓰는지** 확인(헤더 스푸핑 방지). |
| **DB 백업** | 정기 `pg_dump`(§7) + 볼륨 스냅샷. **DB가 모든 realm/user/config의 진실 원천**. |
| **health** | `/health/ready`·`/health/live`(포트 9000) — 헬스체크·모니터링에 연결. |
| **리소스/재시작** | `restart: unless-stopped` + 메모리 제한(`deploy.resources.limits.memory`) + JVM 힙(`JAVA_OPTS_KC_HEAP`). |
| **시크릿** | `.env` chmod 600·git 제외, 또는 docker secrets/외부 시크릿 매니저. |
| **포트 격리** | 외부는 80/443만. 5432/8080/9000은 내부 네트워크 전용. |
| **브루트포스** | 콘솔 Realm settings → Security defenses → Brute force detection on. |

## 7. 백업 / 복구

```bash
# DB 백업 (가장 중요 — 모든 realm/user/config)
docker compose exec -T postgres pg_dump -U keycloak keycloak | gzip > kc-$(date +%F).sql.gz

# 복구
gunzip -c kc-YYYY-MM-DD.sql.gz | docker compose exec -T postgres psql -U keycloak keycloak

# realm 단위 export (설정 위주 — 사용자 비밀번호는 기본 제외)
docker compose exec keycloak /opt/keycloak/bin/kc.sh export --dir /tmp/exp --realm myapp
```

## 8. 업그레이드 절차

Keycloak은 기동 시 **DB 스키마를 자동 마이그레이션**한다:

```bash
# 1) 반드시 DB 백업(§7)  2) Dockerfile 태그 bump(예: 26.6 → 26.7)  3) 재빌드·재기동
docker compose up -d --build
```

> 메이저/마이너 업그레이드 전 릴리스 노트를 확인하고, 롤백 대비 백업을 확보한다. 무중단 업그레이드가 필요하면 Kubernetes + HA 구성(별도 방식)으로 간다.

## 9. 이 SDK 연결

서버가 뜨면 [이 SDK](getting-started.md)를 이렇게 붙인다(§5에서 만든 client 좌표 사용):

```java
// Java
KeycloakConfig.builder()
  .serverUrl("https://auth.example.com")   // 공개 URL(끝에 /auth 없음 — Keycloak 17+ 컨텍스트 제거됨)
  .realm("myapp")
  .clientId("<clientId>")
  .clientSecret("<clientSecret>".toCharArray())
  .build();
```

```python
# Python
KeycloakConfig(server_url="https://auth.example.com", realm="myapp",
               client_id="<clientId>", client_secret="<clientSecret>")
```

---

## 다른 배포 방식이 필요하면

- **Kubernetes(대규모·HA·오토스케일)**: Keycloak Operator 또는 Helm 차트 — 본 문서 범위 밖(요청 시 별도 가이드).
- **VM/베어메탈 직접(systemd)**: 컨테이너 없이 Keycloak 배포판(JVM) + 외부 PostgreSQL + nginx — 요청 시 별도 가이드.

> 공식 레퍼런스: Keycloak Server Guides(컨테이너·데이터베이스·hostname·리버스 프록시·프로덕션 체크리스트).
