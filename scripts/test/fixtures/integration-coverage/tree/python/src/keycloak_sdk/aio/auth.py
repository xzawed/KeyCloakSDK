"""Fixture boundary module (async auth) — the fixture run never imports it."""


class AsyncAuthClient:
    async def token(self) -> str:
        return "tok"
