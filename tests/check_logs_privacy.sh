#!/usr/bin/env bash
# Доказывает, что промпт и ответ не попадают в логи, а факт запроса логируется.
set -euo pipefail
BASE_URL="${BASE_URL:-http://localhost:8000}"
MODEL="${MODEL:-qwen-instruct}"
NS="${NS:-llm}"
API_KEY="${API_KEY:-$(grep '^VLLM_API_KEY=' k8s/overlays/minikube/secrets.env 2>/dev/null | cut -d= -f2- || true)}"
[ -n "$API_KEY" ] || { echo "FAIL: задай API_KEY или заполни k8s/overlays/minikube/secrets.env" >&2; exit 1; }

CANARY="CANARY-$(date +%s)-$RANDOM"
echo "Отправляем промпт с меткой $CANARY"

curl -sf "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Repeat exactly: $CANARY\"}],\"max_tokens\":40}" \
  | jq -r '.choices[0].message.content'

sleep 2
LOGS=$(kubectl -n "$NS" logs deploy/vllm -c vllm --since=5m)

if grep -q "$CANARY" <<< "$LOGS"; then
  echo "FAIL: метка из промпта или ответа найдена в логах"; exit 1
fi
if ! grep -q '"path": "/v1/chat/completions"' <<< "$LOGS"; then
  echo "FAIL: факт обращения не залогирован"; exit 1
fi

echo "OK: промпт и ответ не попали в логи, факт запроса залогирован"
grep '"event": "request"' <<< "$LOGS" | tail -1