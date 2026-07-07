# 설치 검증용 소비 이미지(node 참조 구현) — harness/node(SDK 소스 트리) 접근 없이, Verdaccio에
# 게시된 `@xzawed/keycloak-sdk@0.1.0`을 레지스트리 설치로 조립한다. harness/apps/node/server.js는
# 무변경으로 그대로 재사용한다(빌드 컨텍스트 = 리포지토리 루트 — server.js COPY 경로 때문).
#
# ⚠️ 반드시 `docker build --network install-net ...`로 빌드해야 한다:
#   - 2단계의 `npm install --registry http://verdaccio:4873`가 "verdaccio" 서비스명을 해석해야 하고
#   - 3단계의 quickstart 스모크가 "keycloak" 서비스명을 해석해야 한다(둘 다 install-net 소속).
FROM node:20-alpine AS app
WORKDIR /app

# 1) 설치된 패키지 소비용 최소 package.json — harness/apps/node/package.json(파일 무변경, 별도 사본)의
#    "@xzawed/keycloak-sdk": "file:./xzawed-keycloak-sdk.tgz" 의존성을 레지스트리 설치로 교체한 것.
#    server.js 자체는 3)에서 원본 그대로 COPY한다.
RUN printf '%s' '{"name":"harness-app-node-installed","private":true,"type":"module","engines":{"node":">=20"},"dependencies":{"@xzawed/keycloak-sdk":"0.1.0","express":"^5"}}' > package.json

# 단일 --registry 지정으로 @xzawed/keycloak-sdk뿐 아니라 express(및 SDK의 트랜지티브 의존성 —
# jose/openid-client/@keycloak/keycloak-admin-client)까지 Verdaccio의 npmjs uplink을 통해 해석된다.
RUN npm install --registry http://verdaccio:4873

# 2) 설치 스모크(b1) — quickstart 상당 프로그램을 "설치된 패키지"로 실 Keycloak에 대해 실행해
#    이 RUN이 실패하면(0이 아닌 종료코드) 이미지 빌드 자체가 실패한다 — quickstartOk 게이트.
COPY harness/install/quickstart/node/quickstart.mjs ./quickstart.mjs
RUN KC_SERVER_URL=http://keycloak:8080 KC_REALM=it-realm KC_CLIENT_ID=it-client KC_CLIENT_SECRET=it-secret \
    node quickstart.mjs

# 3) 앱 부팅(b2) — harness/apps/node/server.js 원본 그대로(무변경) 설치된 패키지 의존으로 기동.
COPY harness/apps/node/server.js ./server.js
USER node
EXPOSE 8090
CMD ["node", "server.js"]
