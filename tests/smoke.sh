#!/usr/bin/env bash
# Базовая проверка API и авторизации. Нужен открытый port-forward и переменная API_KEY.
set -euo pipefail
BASE_URL="${BASE_URL:-http://localhost:8000}"
MODEL="${MODEL:-qwen-instruct}"
API_KEY="${API_KEY:-$(grep '^VLLM_API_KEY=' k8s/overlays/minikube/secrets.env 2>/dev/null | cut -d= -f2- || true)}"
[ -n "$API_KEY" ] || { echo "FAIL: задай API_KEY или заполни k8s/overlays/minikube/secrets.env" >&2; exit 1; }

echo "1) /health без ключа → ждём 200"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/health")
[ "$code" = "200" ] || { echo "FAIL: получили $code"; exit 1; }

echo "2) /v1/models без ключа → ждём 401"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/v1/models")
[ "$code" = "401" ] || { echo "FAIL: получили $code"; exit 1; }

echo "3) chat/completions с ключом → ждём ответ модели"
curl -sf "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}],\"max_tokens\":16}" \
  | jq -e '.choices[0].message.content' > /dev/null

echo "OK: smoke test passed"
