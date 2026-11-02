"""ASGI-middleware: одна строка лога на каждый запрос, без промптов и ответов."""
import json
import logging
import time
import uuid

logger = logging.getLogger("audit")
SKIP_PATHS = {"/health", "/metrics"} 

class AuditMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        started = time.perf_counter()
        status = {"code": 500}
        headers = dict(scope.get("headers") or [])
        request_id = headers.get(b"x-request-id", b"").decode() or uuid.uuid4().hex

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                status["code"] = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            if scope["path"] not in SKIP_PATHS:
                logger.info(json.dumps({
                    "event": "request",
                    "request_id": request_id,
                    "method": scope["method"],
                    "path": scope["path"],
                    "status": status["code"],
                    "duration_ms": round((time.perf_counter() - started) * 1000, 1),
                }))