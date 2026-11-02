VERSION ?= 0.1.0
NS      ?= llm
OVERLAY ?= k8s/overlays/minikube

.PHONY: help lock build load deploy forward test restart-test bench-pod bench clean

help:         ## показать список команд
	grep -E '^[a-z-]+:.*##' Makefile | sed 's/:.*##/ —/'

lock:         ## пересобрать uv.lock и requirements.txt (с хешами) для обоих образов
	cd images/vllm && uv lock && uv export --frozen --no-dev --no-emit-project --format requirements-txt -o requirements.txt
	cd images/model-downloader && uv lock && uv export --frozen --no-dev --no-emit-project --format requirements-txt -o requirements.txt

build:        ## собрать оба образа
	docker build -t vllm-cpu:$(VERSION) images/vllm
	docker build -t model-downloader:$(VERSION) images/model-downloader

load:         ## загрузить образы в minikube
	minikube image load vllm-cpu:$(VERSION)
	minikube image load model-downloader:$(VERSION)

deploy:       ## задеплоить и дождаться готовности
	kubectl apply -k $(OVERLAY)
	kubectl -n $(NS) rollout status deploy/vllm --timeout=20m

forward:      ## открыть доступ на localhost:8000 
	kubectl -n $(NS) port-forward svc/vllm 8000:8000

test:         ## smoke-тест + проверка приватности логов
	bash tests/smoke.sh
	bash tests/check_logs_privacy.sh

restart-test: ## проверка, что после рестарта модель берётся с PVC
	bash tests/check_offline_restart.sh

bench-pod:    ## поднять под для нагрузочного теста
	kubectl apply -k bench
	kubectl -n $(NS) wait --for=condition=Ready pod/bench --timeout=5m

bench:        ## нагрузочный тест и таблица
	bash bench/run_bench.sh
	python3 bench/summarize.py

clean:        ## удалить всё из кластера
	kubectl -n $(NS) delete pod bench --ignore-not-found
	kubectl delete -k $(OVERLAY)