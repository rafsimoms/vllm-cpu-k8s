#!/usr/bin/env python3
"""Скачивает веса модели с Hugging Face в примонтированный volume.
Если модель уже на месте, то ничего не делает."""
import logging
import os
import shutil
import sys
import uuid
from pathlib import Path

from huggingface_hub import snapshot_download

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("model-downloader")

MODEL_ID = os.environ["MODEL_ID"]                          
MODEL_REVISION = os.environ.get("MODEL_REVISION", "main")  
MODELS_DIR = Path(os.environ.get("MODELS_DIR", "/models"))
ALLOW_PATTERNS = ["*.json", "*.safetensors", "*.txt", "*.model", "tokenizer*", "*.jinja"]


def main() -> int:
    final_dir = MODELS_DIR / MODEL_ID.replace("/", "__") / MODEL_REVISION
    marker = final_dir / ".complete"

    if marker.exists():
        log.info("Model found locally at %s, skipping download", final_dir)
        return 0

    tmp_dir = final_dir.parent / f".tmp-{uuid.uuid4().hex}"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    log.info("Downloading %s@%s into %s", MODEL_ID, MODEL_REVISION, tmp_dir)
    try:
        snapshot_download(
            repo_id=MODEL_ID,
            revision=MODEL_REVISION,
            local_dir=tmp_dir,
            allow_patterns=ALLOW_PATTERNS,
        )
        if final_dir.exists():
            shutil.rmtree(final_dir)
        tmp_dir.rename(final_dir)
        marker.write_text(f"{MODEL_ID}@{MODEL_REVISION}\n")
    except Exception:
        log.exception("Download failed")
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return 1

    log.info("Model is ready at %s", final_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())