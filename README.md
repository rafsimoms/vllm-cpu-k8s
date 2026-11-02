# vLLM на CPU в Kubernetes

Инференс модели `Qwen/Qwen2.5-0.5B-Instruct` на vLLM 0.27.1 строго на CPU. Деплой в minikube через kustomize. Веса скачивает отдельный initContainer на PVC, секреты приходят из `Secret`, настройки vLLM лежат в `ConfigMap`. Логи не содержат промптов и ответов модели, но каждый запрос фиксируется.

## Структура репозитория

```
images/
  vllm/                     образ vLLM (CPU, rootless)
    Dockerfile
    entrypoint.sh           LD_PRELOAD для tcmalloc и Intel OpenMP, затем vllm serve
    pyproject.toml, uv.lock, requirements.txt
    app/
      privacy_filter.py     фильтр логов: вырезает промпты и ответы
      audit_middleware.py   ASGI middleware: одна строка лога на запрос
      logging_config.json   конфиг логирования vLLM (VLLM_LOGGING_CONFIG_PATH)
  model-downloader/         лёгкий образ для initContainer (rootless)
    Dockerfile
    download_model.py       скачивание весов с HF на PVC
    pyproject.toml, uv.lock, requirements.txt
k8s/
  base/                     общие манифесты
    namespace.yaml, pvc.yaml, service.yaml, deployment.yaml
    config/vllm.yaml        параметры vllm serve (уходят в ConfigMap)
    kustomization.yaml
  overlays/minikube/        настройки под minikube: теги образов и Secret
    kustomization.yaml
    secrets.env.example
```

## Версии

| Компонент | Версия |
|---|---|
| vLLM | 0.27.1 (официальный CPU wheel) |
| torch | 2.13.0+cpu |
| Python | 3.12 (`python:3.12-slim-bookworm`, закреплён по digest) |
| uv | 0.11.29 |
| huggingface_hub | 2.4.0 |
| minikube / Kubernetes | 1.39.0 / 1.37.0 |
| Модель | Qwen/Qwen2.5-0.5B-Instruct, bfloat16 |

## Требования к машине

* x86_64 процессор с AVX2 или AVX-512 (без них vLLM CPU падает с `Illegal instruction`).
* Docker с BuildKit, minikube, kubectl.
* Около 8 ГБ памяти под minikube и 40 ГБ диска.

Решение проверялось на ноутбуке с 16 ГБ RAM: Windows 11, WSL2 (Ubuntu), Docker Desktop. Подробнее про распределение памяти в разделе «Ресурсы».

## Быстрый старт

**1. Собрать образы**

```bash
docker build -t vllm-cpu:0.1.0 images/vllm
docker build -t model-downloader:0.1.0 images/model-downloader
```

**2. Запустить minikube и передать в него образы**

```bash
minikube start --driver=docker --cpus=6 --memory=8g --disk-size=40g
minikube image load vllm-cpu:0.1.0
minikube image load model-downloader:0.1.0
```

**3. Заполнить секреты**

```bash
cp k8s/overlays/minikube/secrets.env.example k8s/overlays/minikube/secrets.env
chmod 600 k8s/overlays/minikube/secrets.env
sed -i "s/^VLLM_API_KEY=.*/VLLM_API_KEY=$(openssl rand -hex 32)/" k8s/overlays/minikube/secrets.env
# HF_TOKEN вписать вручную. Для открытой модели его можно оставить пустым.
```

Файл `secrets.env` указан в `.gitignore` и в репозиторий не попадает.

**4. Задеплоить**

```bash
kubectl apply -k k8s/overlays/minikube
kubectl -n llm get pods -w
```

Первый запуск: загрузка модели занимает от 1 до 3 минут, старт vLLM ещё около 2,5 минут (из них около 2 минут уходит на `torch.compile`). Под готов, когда в колонке READY стоит `1/1`.

**5. Отправить запрос**

```bash
kubectl -n llm port-forward svc/vllm 8000:8000
```

Во втором терминале:

```bash
KEY=$(grep '^VLLM_API_KEY=' k8s/overlays/minikube/secrets.env | cut -d= -f2-)

curl -s http://localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen-instruct","messages":[{"role":"user","content":"Привет!"}],"max_tokens":30}' \
  | jq -r '.choices[0].message.content'
```

**6. Удалить**

```bash
kubectl delete -k k8s/overlays/minikube   # удалит и PVC с весами
minikube delete
```

## Как выполнены требования

### Инференс только на CPU

Образ ставит официальный CPU wheel vLLM (`vllm-0.27.1+cpu`) и torch из индекса `download.pytorch.org/whl/cpu`. CUDA в образе нет. В логе старта видно `device_config=cpu`. Квантизация не используется, веса в `bfloat16`.

Для CPU-бэкенда в `entrypoint.sh` через `LD_PRELOAD` подключаются `libtcmalloc_minimal` и `libiomp5`, как советует документация vLLM. Размер KV-кэша задаёт `VLLM_CPU_KVCACHE_SPACE`, привязку потоков к ядрам задаёт `VLLM_CPU_OMP_THREADS_BIND=auto`. Обе переменные лежат в ConfigMap `vllm-env`.

### Rootless

Оба образа создают пользователя с UID 10001 и переключаются на него через `USER 10001:10001`. В поде дополнительно стоят `runAsNonRoot: true`, `runAsUser: 10001`, `allowPrivilegeEscalation: false` и `capabilities.drop: ["ALL"]`.

Проверка:

```bash
kubectl -n llm exec deploy/vllm -c vllm -- id
# uid=10001(vllm) gid=10001(vllm)
```

### Закреплённые зависимости

Зависимости каждого образа описаны в `pyproject.toml`. Команда `uv lock` фиксирует всё дерево, включая транзитивные пакеты, в `uv.lock`. Команда `uv export` выгружает то же дерево в `requirements.txt` с точными версиями и sha256-хешами.

* `model-downloader` ставится прямо из `requirements.txt`: `uv pip sync --require-hashes`.
* `vllm` ставится из `uv.lock`: `uv sync --locked`. Его `requirements.txt` получен из того же lock-файла, поэтому оба файла описывают одно и то же дерево.

Базовые образы тоже закреплены: Python по sha256-digest, uv по версии.

Обновить зависимости:

```bash
cd images/vllm
uv lock --upgrade-package <пакет>
uv export --frozen --no-dev --no-emit-project --format requirements-txt -o requirements.txt
```

### Логи без промптов и ответов

Логирование vLLM подменяется через `VLLM_LOGGING_CONFIG_PATH=/opt/app/logging_config.json`. Защита устроена в два слоя.

1. **`privacy_filter.PromptRedactionFilter`** висит на единственном handler'е. Записи от логгеров запросов vLLM (`vllm.entrypoints.logger` и `vllm.entrypoints.serve.utils.request_logger`) он отбрасывает целиком. В остальных записях он заменяет на `[REDACTED]` всё, что идёт после `prompt:`, `messages:` и `output:`. Поэтому промпт не попадёт в лог, даже если кто-то включит логирование запросов флагом.
2. **`audit_middleware.AuditMiddleware`** подключается через ключ `middleware` в конфиге vLLM. Middleware не читает тело запроса. На каждый запрос она пишет одну JSON-строку: `request_id`, метод, путь, HTTP-статус и длительность. Пробы `/health` и `/metrics` она пропускает.

Стандартный access-лог uvicorn выключен (`disable-uvicorn-access-log: true`), его заменяет audit-лог.

Проверка в кластере:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen-instruct","messages":[{"role":"user","content":"Повтори: CANARY-777"}],"max_tokens":20}' > /dev/null

kubectl -n llm logs deploy/vllm -c vllm | grep -c CANARY-777          # 0
kubectl -n llm logs deploy/vllm -c vllm | grep '"event": "request"'
```

Результат:

```
0
INFO audit: {"event": "request", "request_id": "d940...", "method": "GET", "path": "/v1/models", "status": 401, "duration_ms": 0.3}
INFO audit: {"event": "request", "request_id": "a68b...", "method": "POST", "path": "/v1/chat/completions", "status": 200, "duration_ms": 4996.1}
```

Контрольный опыт: тот же тест с включённым логированием запросов vLLM (`--enable-log-requests`) тоже даёт 0 совпадений. Значит, промпт останавливает именно фильтр.

### Кэширование модели на PVC

Веса лежат на PVC `model-cache` (10Gi, `ReadWriteOnce`). Скачивает их initContainer `model-downloader` в папку `/models/<org>__<model>/<revision>`.

Логика `download_model.py`:

1. Если в папке модели есть маркер `.complete`, скрипт пишет `skipping download` и выходит. В сеть он не обращается.
2. Иначе он скачивает `snapshot_download` во временную папку рядом с целевой. Скачиваются только нужные файлы (`*.json`, `*.safetensors`, токенизатор).
3. После успешной загрузки временная папка переименовывается в целевую, затем создаётся маркер. Переименование происходит на том же диске, поэтому оно атомарно, и vLLM никогда не увидит модель, скачанную наполовину.
4. При ошибке временная папка удаляется, скрипт выходит с кодом 1, и Kubernetes перезапускает initContainer.

Контейнер vLLM монтирует PVC только на чтение. У него стоят `HF_HUB_OFFLINE=1` и `TRANSFORMERS_OFFLINE=1`, а HF-токена у него нет. Он физически не может скачать модель и работает только с тем, что лежит на диске.

Проверка после рестарта пода:

```bash
kubectl -n llm rollout restart deploy/vllm
kubectl -n llm logs deploy/vllm -c model-downloader
# INFO Model found locally at /models/Qwen__Qwen2.5-0.5B-Instruct/main, skipping download
```

С моделью на диске initContainer завершается за 3 секунды.

### Секреты

Secret `llm-secrets` собирает `secretGenerator` из локального файла `secrets.env`. В git лежит только шаблон `secrets.env.example` с пустыми значениями.

Каждый контейнер получает только свой секрет:

| Секрет | Кому | Зачем |
|---|---|---|
| `HF_TOKEN` | только `model-downloader` | скачивание gated-моделей. Ключ помечен `optional: true`, для открытых моделей его можно не задавать |
| `VLLM_API_KEY` | только `vllm` | Bearer-токен для клиентов API |

Без ключа API отвечает `401`:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000/v1/models   # 401
```

### Настройки через ConfigMap

* `k8s/base/config/vllm.yaml` превращается в ConfigMap `vllm-config`. Он монтируется в `/etc/vllm`, и vLLM читает его флагом `--config`. Ключи совпадают с флагами `vllm serve`: `max-model-len`, `max-num-seqs`, `max-num-batched-tokens` и другие.
* ConfigMap `vllm-env` хранит переменные окружения: модель и её ревизию для загрузчика, а также `VLLM_CPU_*` для vLLM.

Kustomize добавляет к имени ConfigMap хеш содержимого. Любая правка настроек меняет имя, поэтому Deployment перезапускается сам.

Проверка: в `vllm.yaml` значение `max-model-len` поменяли с 2048 на 3072 и выполнили `kubectl apply -k`. Новый под стартовал без пересборки образа.

```bash
kubectl -n llm logs deploy/vllm -c vllm | grep -o 'max_seq_len=[0-9]*'
# max_seq_len=3072
```

## Бонусы

**Бонус 1. Kustomize.** Всё разворачивается командой `kubectl apply -k k8s/overlays/minikube`. В `base` лежат общие манифесты и ConfigMap. В overlay `minikube` лежат теги образов и Secret, то есть всё, что меняется между окружениями.

**Бонус 2. initContainer на отдельном образе.** Скачивание вынесено в `images/model-downloader`. Это отдельный Dockerfile, в нём только Python, `huggingface_hub` и его зависимости. Образ rootless (UID 10001), в поде он работает с `readOnlyRootFilesystem: true`, а служебные файлы HF пишет в `emptyDir` на `/tmp`.

**Бонус 3. Нагрузочное тестирование.**

<!-- TODO: команда запуска, таблица TTFT / Latency / Throughput для коротких и длинных промптов, аналитика по случаям А и Б. -->

## Безопасность пода

* `automountServiceAccountToken: false`: поду не нужен доступ к API Kubernetes.
* `seccompProfile: RuntimeDefault`.
* `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` у обоих контейнеров.
* `readOnlyRootFilesystem: true` у загрузчика.
* PVC с моделью подключён к vLLM в режиме `readOnly`.
* `enableServiceLinks: false` (причина описана ниже).

## Ресурсы

| Что | Значение |
|---|---|
| Память ноутбука | 16 ГБ |
| WSL2 (`.wslconfig`) | `memory=10GB`, `swap=8GB` |
| minikube | `--cpus=6 --memory=8g` |
| vLLM | requests `cpu: 4, memory: 4Gi`, limits `memory: 6Gi` |
| KV-кэш | `VLLM_CPU_KVCACHE_SPACE=1` (1 ГиБ, 87 296 токенов) |
| model-downloader | requests `cpu: 250m, memory: 256Mi`, limits `memory: 1Gi` |

Лимит CPU у vLLM не задан специально. CFS-квота в Kubernetes даёт троттлинг, а инференс на CPU и так упирается в число ядер.

Бюджет minikube меньше памяти WSL. Если vLLM превысит лимит, Kubernetes убьёт только под (`OOMKilled`), а WSL и Docker останутся работать.

## Подводные камни

**`VLLM_PORT 'tcp://...' appears to be a URI`.** Kubernetes добавляет в под переменные окружения для каждого Service в namespace. Для сервиса `vllm` появляется `VLLM_PORT=tcp://10.x.x.x:8000`. Это имя совпадает с настройкой самого vLLM, и движок падает при старте. Решение: `enableServiceLinks: false` в спецификации пода. Сервис доступен по DNS-имени, переменные не нужны.

**Нехватка памяти в WSL.** С настройками по умолчанию (`memory=12GB` из 16, KV-кэш 2 ГиБ, minikube без явного лимита) на пике старта vLLM упала вся виртуальная машина WSL вместе с Docker Desktop. Помогли честный бюджет minikube (меньше памяти WSL), swap для WSL и KV-кэш 1 ГиБ.

**`get_mempolicy: Operation not permitted` в логе vLLM.** vLLM пытается привязать память к NUMA-узлу, а `seccomp RuntimeDefault` и `drop: ALL` это запрещают. На машине с одним NUMA-узлом это ни на что не влияет. Это осознанная цена за ограничения безопасности.

**Обновление образа в minikube.** С тем же тегом и `imagePullPolicy: IfNotPresent` под может продолжить работать на старом образе. После правок надо поднимать тег (`0.1.1`) и менять `newTag` в overlay.

## Известные ограничения

* У контейнера vLLM корневая ФС пока доступна на запись (`readOnlyRootFilesystem: false`).
* Кэш `torch.compile` хранится в `emptyDir`, поэтому после каждого рестарта пода компиляция повторяется, это около 2 минут.
* Если под убить посреди загрузки, временная папка `.tmp-*` останется на PVC. Следующий запуск создаст новую и скачает модель заново.
