#!/usr/bin/env bash
# Нагрузочный тест vLLM изнутри кластера: vllm bench serve в поде bench.
set -euo pipefail
NS="${NS:-llm}"
MODEL_NAME="${MODEL_NAME:-qwen-instruct}"
TOKENIZER="${TOKENIZER:-$(sed -n 's/^model: *//p' k8s/base/config/vllm.yaml)}"
OUTPUT_LEN="${OUTPUT_LEN:-128}"
OUT_DIR="bench/results"

kubectl -n "$NS" get pod bench > /dev/null 2>&1 \
  || { echo "Нет пода bench: сначала make bench-pod" >&2; exit 1; }
mkdir -p "$OUT_DIR"

run() { 
  local in_len=$1 conc=$2 num=$3 name="in$1_c$2"
  echo "=== $name: вход $in_len, выход $OUTPUT_LEN, параллельно $conc, запросов $num"
  kubectl -n "$NS" exec bench -- vllm bench serve \
    --backend openai-chat \
    --base-url http://vllm:8000 \
    --endpoint /v1/chat/completions \
    --model "$MODEL_NAME" \
    --tokenizer "$TOKENIZER" \
    --dataset-name random \
    --random-input-len "$in_len" \
    --random-output-len "$OUTPUT_LEN" \
    --ignore-eos \
    --num-prompts "$num" \
    --max-concurrency "$conc" \
    --seed 42 \
    --percentile-metrics ttft,tpot,itl,e2el \
    --metric-percentiles 50,99 \
    --save-result --result-dir /tmp/results --result-filename "$name.json"
  kubectl -n "$NS" exec bench -- cat "/tmp/results/$name.json" > "$OUT_DIR/$name.json"
}

run 128 1 4 && rm -f "$OUT_DIR/in128_c1.json"

run 128 1 10
run 128 4 20
run 128 8 32
run 2048 1 6
run 2048 4 12

echo "Готово. Таблица: python3 bench/summarize.py"