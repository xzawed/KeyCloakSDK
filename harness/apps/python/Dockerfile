# build context = repo root
# python:3.12-slim(Debian/glibc)은 Docker Desktop(Windows)에서 CNAME 체인(files.pythonhosted.org,
# Fastly CDN) 이름해석에 실패해 pip install이 DNS 오류로 죽는다(Task 1에서 실측). musl(alpine)
# 리졸버는 동일 환경에서 정상 동작 — 로컬/CI 양쪽에서 안정적으로 빌드되도록 alpine을 사용한다.
FROM python:3.12-alpine
WORKDIR /app
# SDK 소스 로컬 설치(hatchling 휠 빌드) — 실제 배포 패키지 소비
COPY python/ /sdk/
RUN pip install --no-cache-dir /sdk
COPY harness/apps/python/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY harness/apps/python/main.py ./main.py
RUN addgroup -g 10001 app && adduser -D -u 10001 -G app app
USER app
EXPOSE 8090
# uvicorn 단일 워커 + 비동기 이벤트 루프로 동시성(aio 미러 실측 쇼케이스)
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${APP_PORT:-8090}"]
