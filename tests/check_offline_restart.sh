#!/usr/bin/env bash
# Доказывает, что после рестарта пода модель берётся с PVC, а не скачивается заново.
set -euo pipefail
NS="${NS:-llm}"

echo "Перезапускаем под..."
kubectl -n "$NS" rollout restart deploy/vllm
kubectl -n "$NS" rollout status deploy/vllm --timeout=15m

if kubectl -n "$NS" logs deploy/vllm -c model-downloader | grep -q 'skipping download'; then
  echo "OK: модель взята с PVC, повторной загрузки не было"
else
  echo "FAIL: загрузчик снова скачивал модель"; exit 1
fi