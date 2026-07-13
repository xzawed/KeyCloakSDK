# Keycloak Server Deployment Guide — Single VM + Docker Compose (Production)

> **This document is about standing up the Keycloak *server*, not this SDK.** This SDK (`keycloak-sdk`) is only a **client library** — it does not include a Keycloak server. Keycloak is a **finished, open-source server** built by Red Hat: we don't *implement* the server, we simply **pull it in and run (deploy)** it (the same way you run PostgreSQL or nginx without coding them). For the conceptual overview, see [getting-started](getting-started.md).

**Audience**: operators who want to stand up a production-grade Keycloak on a single VM (a cloud instance or an on-prem server). This is a good fit for small-to-medium, single-node setups (if you need HA or autoscaling, use the Kubernetes + Operator approach instead).

**Version baseline**: Keycloak **26.x** (this SDK is verified against 26.6.x). The configuration keys follow the official 26.x documentation.

```
Internet ──443──▶ Caddy (TLS termination, automatic Let's Encrypt)
                  │ internal HTTP(8080)
                  ▼
              Keycloak 26.x ──JDBC──▶ PostgreSQL (persistent volume)
              (start --optimized · http-enabled · proxy-headers)
```

---

## 0. Prerequisites

- **VM**: 2 vCPU / 4GB RAM or more, with Docker + Docker Compose (v2) installed.
- **Domain**: an `auth.example.com` A record → the VM's public IP.
- **Firewall**: **open only 80/443**. `5432` (DB), `8080` (KC HTTP), and `9000` (management/health) stay closed to the outside.
- **Why an external DB**: the development `start-dev` mode uses the embedded H2, but in production it is **forbidden** because of data loss and migration problems. Always use an external DB such as PostgreSQL.

## 1. Directory & Secrets

```
keycloak-deploy/
├─ .env                # secrets (never commit to git, chmod 600)
├─ docker-compose.yml
├─ Dockerfile          # optimized Keycloak image
└─ Caddyfile
```

**`.env`** — generate with strong random values (`openssl rand -base64 32`):

```dotenv
KC_DB_PASSWORD=<strong-random-DB-password>
KC_BOOTSTRAP_ADMIN_PASSWORD=<strong-random-temporary-admin-password>
KC_HOSTNAME=https://auth.example.com
ACME_EMAIL=you@example.com
```

## 2. Optimized Keycloak Image (`Dockerfile`)

Baking the build-time options (`KC_DB`, health, metrics) into an **optimized image** ahead of time speeds up startup and lets you use `start --optimized`:

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

> ⚠️ Pin the image tag **down to the patch version**, matching the version this SDK is verified against (26.6.x). `KC_HEALTH_ENABLED` / `KC_METRICS_ENABLED` / `KC_DB` are **build-time** options, so they get baked into the image.

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
    # no external port exposure (internal network only)

  keycloak:
    build: .
    restart: unless-stopped
    command: start --optimized
    environment:
      # DB (runtime options)
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${KC_DB_PASSWORD}
      # hostname v2 — full public URL
      KC_HOSTNAME: ${KC_HOSTNAME}
      KC_HOSTNAME_STRICT: "true"
      # reverse proxy (Caddy) terminates TLS → internal is HTTP + trust proxy headers
      KC_HTTP_ENABLED: "true"
      KC_PROXY_HEADERS: xforwarded
      # initial bootstrap admin (replace and remove immediately after first login)
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KC_BOOTSTRAP_ADMIN_PASSWORD}
      # structured logging (optional)
      KC_LOG_CONSOLE_OUTPUT: json
    depends_on:
      postgres: { condition: service_healthy }
    healthcheck:
      # the official KC image has no curl, so check management-port (9000) readiness via bash /dev/tcp
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

## 4. `Caddyfile` (Automatic HTTPS)

```
auth.example.com {
    reverse_proxy keycloak:8080
    encode gzip
}
```

> Caddy **automatically issues and renews** certificates via Let's Encrypt (requires 80/443 to be open). If you use nginx/Traefik, you configure certificate management and `X-Forwarded-*` header forwarding yourself.

## 5. Startup & Initial Bootstrap

```bash
docker compose up -d --build
docker compose logs -f keycloak          # look for "Running the server in production mode" / "started"
```

1. Open the `https://auth.example.com` admin console → log in as `admin` with the temporary password (from `.env`).
2. **Create a realm** (e.g. `myapp`) → **register a client** (confidential, *Service accounts roles* on → obtain `clientId`/`clientSecret`) → create a user.
3. **Replace the bootstrap admin**: create a personal admin account in the master realm → delete the temporary `admin` account → remove `KC_BOOTSTRAP_ADMIN_*` from compose (it's for the first-run only).

## 6. Production Must-Do Checklist

| Item | Action |
|---|---|
| **TLS** | Caddy automatic HTTPS (or proxy certificate). If Keycloak terminates HTTPS directly, `KC_HTTPS_CERTIFICATE_FILE`/`KC_HTTPS_CERTIFICATE_KEY_FILE` (PEM). |
| **hostname** | `KC_HOSTNAME` = full public URL + `KC_HOSTNAME_STRICT=true`. |
| **proxy headers** | `KC_PROXY_HEADERS=xforwarded` + confirm the proxy **overwrites** `X-Forwarded-*` (prevents header spoofing). |
| **DB backup** | regular `pg_dump` (§7) + volume snapshots. **The DB is the source of truth for all realms/users/config.** |
| **health** | `/health/ready` · `/health/live` (port 9000) — wire into health checks / monitoring. |
| **resources/restart** | `restart: unless-stopped` + memory limit (`deploy.resources.limits.memory`) + JVM heap (`JAVA_OPTS_KC_HEAP`). |
| **secrets** | `.env` chmod 600 · exclude from git, or use docker secrets / an external secret manager. |
| **port isolation** | only 80/443 externally. 5432/8080/9000 are internal-network only. |
| **brute force** | Console Realm settings → Security defenses → Brute force detection on. |

## 7. Backup / Restore

```bash
# DB backup (most important — all realms/users/config)
docker compose exec -T postgres pg_dump -U keycloak keycloak | gzip > kc-$(date +%F).sql.gz

# restore
gunzip -c kc-YYYY-MM-DD.sql.gz | docker compose exec -T postgres psql -U keycloak keycloak

# per-realm export (config-focused — user passwords excluded by default)
docker compose exec keycloak /opt/keycloak/bin/kc.sh export --dir /tmp/exp --realm myapp
```

## 8. Upgrade Procedure

Keycloak **automatically migrates the DB schema** at startup:

```bash
# 1) always back up the DB (§7)  2) bump the Dockerfile tag (e.g. 26.6 → 26.7)  3) rebuild & restart
docker compose up -d --build
```

> Review the release notes before any major/minor upgrade, and secure a backup in case you need to roll back. If you need zero-downtime upgrades, move to a Kubernetes + HA configuration (a separate approach).

## 9. Connecting This SDK

Once the server is up, wire in [this SDK](getting-started.md) like this (using the client coordinates you created in §5):

```java
// Java
KeycloakConfig.builder()
  .serverUrl("https://auth.example.com")   // public URL (no trailing /auth — Keycloak 17+ dropped the context path)
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

## If You Need a Different Deployment Model

- **Kubernetes (large-scale, HA, autoscaling)**: the Keycloak Operator or a Helm chart — out of scope for this document (a separate guide is available on request).
- **VM/bare-metal directly (systemd)**: the Keycloak distribution (JVM) without containers + external PostgreSQL + nginx — a separate guide is available on request.

> Official references: the Keycloak Server Guides (containers, database, hostname, reverse proxy, production checklist).
