# build context = repo root
FROM node:22-alpine AS sdk
WORKDIR /sdk
COPY node/ ./
# SDK 빌드(dist) 후 배포 형상 tarball 생성(files:["dist"]만 포함)
# npm pack --pack-destination은 대상 디렉터리를 자동 생성하지 않음(ENOENT) — 먼저 mkdir
RUN mkdir -p /pack && npm ci && npm run build && npm pack --pack-destination /pack

FROM node:22-alpine AS app
WORKDIR /app
COPY harness/apps/node/package.json ./package.json
# npm pack 산출물(xzawed-keycloak-sdk-<ver>.tgz)을 package.json이 참조하는 고정 이름으로 배치
COPY --from=sdk /pack/*.tgz ./xzawed-keycloak-sdk.tgz
COPY harness/apps/node/server.js ./server.js
RUN npm install --omit=dev
USER node
EXPOSE 8090
CMD ["node", "server.js"]
