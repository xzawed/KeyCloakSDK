# build context = repo root (docker-compose.yml의 context: ..)
FROM golang:1.25-alpine AS build
WORKDIR /app
# SDK 소스를 /sdk로 복사(go.mod의 replace 대상)
COPY go/ /sdk/
# 앱 소스
COPY harness/apps/go/go.mod ./go.mod
COPY harness/apps/go/main.go ./main.go
RUN go mod tidy && go build -o /out/app .

FROM alpine:3.20
RUN adduser -D -u 10001 app
COPY --from=build /out/app /usr/local/bin/app
USER app
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/app"]
