# SCAManager

`git push` 시 diff를 AI로 코드리뷰하고 결과를 SCAManager 서버로 보고하는 pre-push 훅.

## 설치

```bash
bash .scamanager/install-hook.sh   # .git/hooks/pre-push 설치 (로컬, 커밋 안 됨)
```

## 토큰 설정 (⚠️ 커밋 금지)

인증 토큰은 **절대 `config.json`에 커밋하지 않는다.** 훅은 아래 우선순위로 토큰을 읽는다:

1. 환경변수 **`SCAMANAGER_TOKEN`** (권장)
2. 없으면 로컬 파일 **`.scamanager/token`** (gitignore됨, mode 600)

```bash
# 방법 A) 환경변수
export SCAMANAGER_TOKEN='<발급받은-토큰>'

# 방법 B) 로컬 파일 (gitignore됨)
printf '%s' '<발급받은-토큰>' > .scamanager/token
chmod 600 .scamanager/token
```

토큰이 없으면 훅은 리뷰를 **건너뛰고** push는 정상 진행된다.

## config.json (커밋됨 — 비밀 아님)

```json
{ "server": "<서버 URL>", "repo": "<owner/repo>" }
```

## 동작 & 요구사항

- 매 `git push` 시: 서버 verify(200) → diff/커밋메시지로 Anthropic API 리뷰(`ANTHROPIC_API_KEY` 필요) → 서버로 결과 POST.
- `ANTHROPIC_API_KEY` 미설정 시 리뷰를 건너뛴다.
- 리뷰 결과·커밋메타가 `server`로 전송된다(운영 정책에 맞게 사용).

## 끄기

```bash
rm .git/hooks/pre-push
```
