"""Фильтр логов: не пропускает промпты и ответы модели."""
import logging
import re

BLOCKED_LOGGERS = ("vllm.entrypoints.logger",)

_SENSITIVE = re.compile(
    r"\b(prompt|prompt_token_ids|messages|outputs?)\s*[:=].*",
    re.IGNORECASE | re.DOTALL,
)


class PromptRedactionFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        if record.name.startswith(BLOCKED_LOGGERS):
            return False
        try:
            message = record.getMessage()
        except Exception:
            message = "[log message could not be formatted]"

        message = _SENSITIVE.sub(r"\1: [REDACTED]", message)
        record.msg = message
        record.args = ()
        return True