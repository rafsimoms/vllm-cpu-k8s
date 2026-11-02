# vLLM на CPU в Kubernetes

Инференс модели `Qwen/Qwen2.5-0.5B-Instruct` на vLLM 0.27.1 строго на CPU. Деплой в minikube через kustomize. Веса скачивает отдельный initContainer на PVC, секреты приходят из `Secret`, настройки vLLM лежат в `ConfigMap`. Логи не содержат промптов и ответов модели, но каждый запрос фиксируется. Выполнение требований проверяется скриптами командой `make test`, нагрузочный тест запускается командой `make bench`.

## Структура репозитория

```
Makefile                    сборка, деплой, тесты и бенчмарк одной командой (make help)
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
tests/
  smoke.sh                  API отвечает и закрыт ключом
  check_logs_privacy.sh     промпт и ответ не попадают в лог, факт запроса попадает
  check_offline_restart.sh  после рестарта пода модель берётся с PVC
bench/                      нагрузочный тест (бонус 3)
  kustomization.yaml        overlay: весь стенд плюс под с клиентом
  bench-pod.yaml            под с vllm bench serve
  run_bench.sh              прогон сценариев
  summarize.py              JSON с результатами в markdown-таблицу
  results/                  сырые результаты и summary.md
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
| Ревизия модели | `7ae557604adf67be50417f59c2c2f167def9a775` |

Ревизия модели закреплена по commit SHA, а не по ветке `main`: содержимое `main` на Hugging Face может поменяться, а конкретный коммит нет.

Модель 0.5B выбрана вместо 1.5B из примера в задании из-за памяти. На ноутбуке с 16 ГБ RAM рядом с Windows, WSL и Docker Desktop под vLLM остаётся около 6 ГБ. Даже с моделью 0.5B на пике старта vLLM однажды упала вся WSL (см. «Подводные камни»), поэтому модель втрое больше на этом стенде не запускалась. Чтобы взять другую модель, достаточно поменять `MODEL_ID` и `MODEL_REVISION` в `k8s/base/kustomization.yaml` и путь `model` в `k8s/base/config/vllm.yaml`.

## Требования к машине

* x86_64 процессор с AVX2 или AVX-512 (без них vLLM CPU падает с `Illegal instruction`).
* Docker с BuildKit, minikube, kubectl, `make`, `curl`, `jq`.
* Около 8 ГБ памяти под minikube и 40 ГБ диска.

Решение проверялось на ноутбуке с 16 ГБ RAM: Windows 11, WSL2 (Ubuntu), Docker Desktop. Подробнее в разделе «Ресурсы».

## Быстрый старт

Все шаги собраны в `Makefile`, список целей показывает `make help`. Ниже для каждого шага указаны цель и команды, которые она выполняет.

**1. Собрать образы**

```bash
make build
# docker build -t vllm-cpu:0.1.0 images/vllm
# docker build -t model-downloader:0.1.0 images/model-downloader
```

Тег задаёт переменная `VERSION` (по умолчанию `0.1.0`): `make build VERSION=0.1.1`.

**2. Запустить minikube и передать в него образы**

```bash
minikube start --driver=docker --cpus=6 --memory=8g --disk-size=40g
make load
# minikube image load vllm-cpu:0.1.0
# minikube image load model-downloader:0.1.0
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
make deploy
# kubectl apply -k k8s/overlays/minikube
# kubectl -n llm rollout status deploy/vllm --timeout=20m
```

Команда ждёт, пока под станет готов. Первый запуск занимает около 4 или 5 минут: загрузка модели от 1 до 3 минут, старт vLLM около 2,5 минут (из них около 2 минут уходит на `torch.compile`).

**5. Отправить запрос**

```bash
make forward
# kubectl -n llm port-forward svc/vllm 8000:8000
```

Во втором терминале:

```bash
export API_KEY=$(grep '^VLLM_API_KEY=' k8s/overlays/minikube/secrets.env | cut -d= -f2-)

curl -s http://localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen-instruct","messages":[{"role":"user","content":"Привет!"}],"max_tokens":30}' \
  | jq -r '.choices[0].message.content'
```

**6. Нагрузочный тест (необязательно)**

```bash
make bench-pod
make bench
```

Подробности в разделе «Бонус 3».

**7. Удалить**

```bash
make clean        # удалит под bench и весь стенд, включая PVC с весами
minikube delete
```

## Проверка

Тестам нужен открытый `make forward` в соседнем терминале. Ключ API скрипты берут из переменной `API_KEY`, а если она не задана, то из `k8s/overlays/minikube/secrets.env`.

```bash
make test           # smoke.sh и check_logs_privacy.sh, около 15 секунд
make restart-test   # check_offline_restart.sh, около 3 или 4 минут
```

| Скрипт | Что проверяет |
|---|---|
| `tests/smoke.sh` | `/health` отвечает 200 без ключа. `/v1/models` без ключа отвечает 401. Запрос к `/v1/chat/completions` с ключом возвращает ответ модели |
| `tests/check_logs_privacy.sh` | отправляет промпт с уникальной меткой `CANARY-<время>-<случайное число>` и просит модель её повторить. Затем ищет метку в логе vLLM: её быть не должно. Строка audit о запросе к `/v1/chat/completions` быть должна |
| `tests/check_offline_restart.sh` | делает `rollout restart`, ждёт готовности нового пода и ищет `skipping download` в логе initContainer |

Каждый скрипт выходит с кодом 0 при успехе и с кодом 1 при ошибке, поэтому `make` останавливается на первом упавшем тесте.

`make restart-test` пересоздаёт под. Port-forward привязан к старому поду, после теста его нужно перезапустить.

Пример вывода `make test`:

```
1) /health без ключа → ждём 200
2) /v1/models без ключа → ждём 401
3) chat/completions с ключом → ждём ответ модели
OK: smoke test passed
Отправляем промпт с меткой CANARY-1793634991-5006
CANARY-1793634991-5006 is an alphanumeric string that represents a unique identifier ...
OK: промпт и ответ не попали в логи, факт запроса залогирован
INFO audit: {"event": "request", "request_id": "a516...", "method": "POST", "path": "/v1/chat/completions", "status": 200, "duration_ms": 3678.9}
```

Модель повторила метку в ответе. Значит, метка была и в запросе, и в ответе, и всё равно не попала в лог.

## Как выполнены требования

### Инференс только на CPU

Образ ставит официальный CPU wheel vLLM (`vllm-0.27.1+cpu`) и torch из индекса `download.pytorch.org/whl/cpu`. CUDA в образе нет. В логе старта видно `device_config=cpu`. Квантизация не используется, веса в `bfloat16`.

Для CPU-бэкенда в `entrypoint.sh` через `LD_PRELOAD` подключаются `libtcmalloc_minimal` и `libiomp5`, как советует документация vLLM. Размер KV-кэша задаёт `VLLM_CPU_KVCACHE_SPACE`, привязку потоков к ядрам задаёт `VLLM_CPU_OMP_THREADS_BIND=auto`. Обе переменные лежат в ConfigMap `vllm-env`.

### Rootless

Оба образа создают пользователя с UID 10001 и переключаются на него через `USER 10001:10001`. В поде дополнительно стоят `runAsNonRoot: true`, `runAsUser: 10001`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` и `readOnlyRootFilesystem: true` (подробнее в разделе «Безопасность пода»).

```bash
kubectl -n llm exec deploy/vllm -c vllm -- id
# uid=10001(vllm) gid=10001(vllm)
```

### Закреплённые зависимости

Зависимости каждого образа описаны в `pyproject.toml`. Команда `uv lock` фиксирует всё дерево, включая транзитивные пакеты, в `uv.lock`. Команда `uv export` выгружает то же дерево в `requirements.txt` с точными версиями и sha256-хешами.

* `model-downloader` ставится прямо из `requirements.txt`: `uv pip sync --require-hashes`.
* `vllm` ставится из `uv.lock`: `uv sync --locked`. Его `requirements.txt` получен из того же lock-файла, поэтому оба файла описывают одно и то же дерево.

Почему vLLM ставится не из `requirements.txt`. Пакеты для этого образа приходят из трёх источников: колесо vLLM из GitHub Releases, torch и его библиотеки из CPU-индекса PyTorch, остальное из PyPI. В формате `requirements.txt` нельзя указать индекс для отдельного пакета. Если подключить индекс PyTorch через `--extra-index-url`, uv начинает искать в нём и обычные пакеты. Часть из них там есть, но не во всех версиях, и установка падает. `uv.lock` хранит источник каждого пакета, поэтому установка из него работает.

Базовые образы тоже закреплены: Python по sha256-digest, uv по версии.

Пересобрать lock-файлы и `requirements.txt` для обоих образов:

```bash
make lock
```

### Логи без промптов и ответов

Логирование vLLM подменяется через `VLLM_LOGGING_CONFIG_PATH=/opt/app/logging_config.json`. Защита устроена в два слоя.

1. **`privacy_filter.PromptRedactionFilter`** висит на единственном handler'е. Записи от логгеров запросов vLLM (`vllm.entrypoints.logger` и `vllm.entrypoints.serve.utils.request_logger`) он отбрасывает целиком. В остальных записях он заменяет на `[REDACTED]` всё, что идёт после `prompt:`, `messages:` и `output:`. Поэтому промпт не попадёт в лог, даже если кто-то включит логирование запросов флагом.
2. **`audit_middleware.AuditMiddleware`** подключается через ключ `middleware` в конфиге vLLM. Middleware не читает тело запроса. На каждый запрос она пишет одну JSON-строку: `request_id` (из заголовка `X-Request-ID` или случайный), метод, путь, HTTP-статус и длительность. Пробы `/health` и `/metrics` она пропускает.

Стандартный access-лог uvicorn выключен (`disable-uvicorn-access-log: true`), его заменяет audit-лог.

Автоматическая проверка: `tests/check_logs_privacy.sh` (см. «Проверка»). Пример audit-строк, включая отклонённый запрос без ключа:

```
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

Автоматическая проверка: `make restart-test`. Вручную:

```bash
kubectl -n llm rollout restart deploy/vllm
kubectl -n llm logs deploy/vllm -c model-downloader
# INFO Model found locally at /models/Qwen__Qwen2.5-0.5B-Instruct/7ae557604adf67be50417f59c2c2f167def9a775, skipping download
```

С моделью на диске initContainer завершается за 3 секунды.

### Секреты

Secret `llm-secrets` собирает `secretGenerator` из локального файла `secrets.env`. В git лежит только шаблон `secrets.env.example` с пустыми значениями.

Каждый контейнер получает только свой секрет:

| Секрет | Кому | Зачем |
|---|---|---|
| `HF_TOKEN` | только `model-downloader` | скачивание gated-моделей. Ключ помечен `optional: true`, для открытых моделей его можно не задавать |
| `VLLM_API_KEY` | только `vllm` | Bearer-токен для клиентов API |

Без ключа API отвечает `401`, это проверяет `tests/smoke.sh`. Ключ закрывает все пути `/v1/*`. Пути `/health` и `/metrics` открыты без ключа: первый нужен пробам Kubernetes, второй системе мониторинга.

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

### Бонус 1. Kustomize

Всё разворачивается командой `kubectl apply -k k8s/overlays/minikube`. В `base` лежат общие манифесты и ConfigMap. В overlay `minikube` лежат теги образов и Secret, то есть всё, что меняется между окружениями.

### Бонус 2. initContainer на отдельном образе

Скачивание вынесено в `images/model-downloader`. Это отдельный Dockerfile, в нём только Python, `huggingface_hub` и его зависимости. Образ rootless (UID 10001), в поде он работает с `readOnlyRootFilesystem: true`, а служебные файлы HF пишет в `emptyDir` на `/tmp`.

### Бонус 3. Нагрузочное тестирование

Клиент `vllm bench serve` уже есть в образе vLLM. Он работает в отдельном поде `bench` внутри кластера и обращается к сервису `vllm:8000` напрямую, поэтому port-forward не искажает задержки.

```bash
make bench-pod                      # kubectl apply -k bench, ждёт готовности пода
make bench                          # bench/run_bench.sh, затем bench/summarize.py
kubectl -n llm delete pod bench     # убрать клиента после теста
```

Прогон занимает около 40 минут. Сырые результаты лежат в `bench/results/*.json`, таблица в `bench/results/summary.md`.

Под `bench` удаляется только командой `kubectl -n llm delete pod bench`. Команду `kubectl delete -k bench` использовать нельзя: overlay `bench` включает весь стенд, и она удалит vLLM вместе с PVC.

**Как устроен тест**

* `bench/kustomization.yaml` подключает overlay `minikube` и добавляет к нему под. Так kustomize сам подставляет в под имя Secret с хешем, который добавляет `secretGenerator`. Тег образа из overlay `minikube` на под не распространяется, поэтому он повторён в блоке `images:`.
* Под работает с теми же ограничениями безопасности, что и vLLM. Ключ API он получает из Secret в переменной `OPENAI_API_KEY`, токенизатор читает с PVC в режиме только для чтения.
* У пода лимит в 1 CPU. Клиент делит ноутбук с сервером, и лимит не даёт ему забирать ядра у vLLM.
* Сценарии: вход 128 токенов при 1, 4 и 8 одновременных запросах, вход 2048 токенов при 1 и 4. Выход везде ровно 128 токенов (`--ignore-eos`), поэтому сценарии можно сравнивать между собой. Датасет `random`, `seed 42`.
* Перед замерами идёт прогревочный прогон. Первые запросы после старта медленнее, и в таблицу он не попадает.

**Условия**

| Параметр | Значение |
|---|---|
| Процессор | Intel Core i5-1135G7, 4 ядра / 8 потоков |
| minikube | 6 CPU, 8 ГБ |
| Под vLLM | requests 4 CPU, лимита CPU нет. Вычисления идут на трёх физических ядрах (см. «Ресурсы») |
| Под bench | limit 1 CPU, работает на той же машине |
| Модель | Qwen2.5-0.5B-Instruct, bfloat16, без квантизации |
| vLLM | `max-model-len 3072`, `max-num-seqs 16`, `max-num-batched-tokens 4096`, KV-кэш 1 ГиБ |

**Результаты**

| Вход, ток | Параллельно | Успешно | TTFT p50, мс | TTFT p99, мс | TPOT p50, мс | Latency p50, с | Latency p99, с | Запросов/с | Выход, ток/с | Всего, ток/с |
|---|---|---|---|---|---|---|---|---|---|---|
| 128 | 1 | 10/10 | 2598 | 2743 | 86.1 | 13.55 | 13.83 | 0.08 | 9.9 | 22.0 |
| 128 | 4 | 20/20 | 2806 | 10128 | 217.6 | 33.30 | 39.36 | 0.12 | 15.1 | 33.5 |
| 128 | 8 | 32/32 | 4183 | 19966 | 473.2 | 68.79 | 80.09 | 0.11 | 14.6 | 32.4 |
| 2048 | 1 | 6/6 | 30352 | 33556 | 93.3 | 42.51 | 45.51 | 0.02 | 3.1 | 53.9 |
| 2048 | 4 | 12/12 | 34814 | 89213 | 198.1 | 71.54 | 116.36 | 0.06 | 7.1 | 122.5 |

* **TTFT** (Time To First Token): время до первого токена ответа. Сюда входит и ожидание в очереди.
* **TPOT** (Time Per Output Token): среднее время на каждый следующий токен.
* **Latency**: полное время запроса от отправки до последнего токена.
* **Throughput**: «Выход» считает только сгенерированные токены, «Всего» считает входные и выходные вместе.

Это один прогон на ноутбуке, где клиент и сервер делят одни и те же ядра. Цифры показывают порядок величин и тенденции, а не предельную производительность.

**Что видно из цифр**

* Обработка промпта (prefill) идёт около 67 ток/с: 2048 токенов занимают 30 с до первого токена. Для длинных запросов это главное узкое место.
* Генерация одного потока идёт около 11,6 ток/с (TPOT 86 мс).
* Для коротких запросов выход растёт с 9,9 до 15,1 ток/с при переходе с 1 на 4 одновременных запроса. При 8 запросах он уже не растёт (14,6 ток/с). TPOT при этом растёт почти пропорционально числу запросов: 86, 218 и 473 мс. Процессор загружен вычислениями полностью уже при батче около 4, и больший батч только удлиняет ожидание каждого запроса.
* Для длинных запросов батч из 4 даёт рост общей пропускной способности в 2,3 раза (53,9 и 122,5 ток/с). Обработка нескольких длинных промптов за один шаг загружает матричные операции эффективнее.
* Большие хвосты TTFT под нагрузкой (p99 20 с у коротких при 8 запросах, 89 с у длинных при 4) объясняются очередью. Новый запрос ждёт, пока освободится место в батче и закончится обработка чужих длинных промптов.

**Как поднять Throughput**

*А) Большой поток запросов с небольшим числом токенов.* Узкое место здесь в генерации. Пропускную способность даёт обработка многих запросов одним батчем.

* `max-num-seqs`. Это верхняя граница батча и главный рычаг на машине с запасом вычислений. На этом стенде рост остановился уже на 4 запросах, значит, батч упирается в CPU, а не в настройку.
* Больше ядер для вычислений. Сейчас `VLLM_CPU_OMP_THREADS_BIND=auto` отдаёт vLLM три физических ядра. На сервере стоит выделить поду целые ядра (Guaranteed QoS и политика `static` у CPU Manager в kubelet) и задать привязку потоков явно.
* `VLLM_CPU_KVCACHE_SPACE`. KV-кэш должен вмещать весь батч. Иначе vLLM вытесняет запросы и потом пересчитывает их заново.
* Квантизация весов, например INT8. Она уменьшает объём вычислений и чтения памяти на каждый токен. Поддерживаемые на CPU методы нужно сверить с документацией vLLM.
* Тип данных. У i5-1135G7 нет инструкций `avx512_bf16`, поэтому операции в bfloat16 выполняются через преобразование в float32. На этом процессоре стоит отдельно замерить `dtype: float32`, он может оказаться быстрее. Здесь это не проверялось.
* Prefix caching (`enable-prefix-caching`). Если у запросов общий системный промпт, vLLM не будет обрабатывать его заново для каждого запроса.
* Горизонтальное масштабирование. Несколько реплик, каждая на своих ядрах (на многосокетном сервере по реплике на NUMA-узел), обычно дают больше, чем один большой под.

*Б) Запросов меньше, но в них огромное количество токенов.* Узкое место здесь в обработке промпта и в объёме KV-кэша.

* Chunked prefill и `max-num-batched-tokens`. Длинный промпт обрабатывается кусками, поэтому он не блокирует генерацию у остальных запросов. Больший `max-num-batched-tokens` ускоряет prefill, потому что крупные куски эффективнее загружают матричные операции. Цена в том, что растёт задержка между токенами у соседних запросов.
* Prefix caching. Если длинный контекст повторяется (один документ, RAG, многоходовой диалог), повторная обработка промпта исчезает. Для таких нагрузок это самый большой выигрыш.
* `VLLM_CPU_KVCACHE_SPACE` и `max-model-len`. KV-кэш должен вмещать несколько длинных последовательностей одновременно, а `max-model-len` не должен быть больше реально нужного.
* Меньший `max-num-seqs`. Тогда несколько длинных запросов не вытесняют друг друга из KV-кэша и не пересчитываются заново.
* Квантизация и тип данных. Как и в случае А, они уменьшают объём вычислений, а prefill на CPU упирается именно в вычисления.

## Безопасность пода

* `automountServiceAccountToken: false`: поду не нужен доступ к API Kubernetes.
* `seccompProfile: RuntimeDefault`.
* `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` у обоих контейнеров.
* `readOnlyRootFilesystem: true` у обоих контейнеров. vLLM пишет только в `emptyDir`: `/tmp` (сюда пишет `torch.compile`), `/home/vllm/.cache` (кэш vLLM), `/home/vllm/.config` и `/dev/shm`.
* PVC с моделью подключён к vLLM в режиме `readOnly`.
* Телеметрия vLLM выключена: `VLLM_NO_USAGE_STATS=1` и `DO_NOT_TRACK=1`.
* `enableServiceLinks: false` (причина описана в «Подводных камнях»).

Те же настройки стоят у пода `bench`.

Проверка read-only файловой системы:

```bash
kubectl -n llm exec deploy/vllm -c vllm -- touch /opt/app/hacked
# touch: cannot touch '/opt/app/hacked': Read-only file system

kubectl -n llm exec deploy/vllm -c vllm -- touch /tmp/ok && echo "запись в /tmp работает"
# запись в /tmp работает
```

## Ресурсы

Стенд:

| Что | Значение |
|---|---|
| Процессор | Intel Core i5-1135G7, 4 ядра / 8 потоков |
| Память ноутбука | 16 ГБ |
| WSL2 (`.wslconfig`) | `memory=10GB`, `swap=8GB` |
| minikube | `--cpus=6 --memory=8g` |

Под:

| Контейнер | requests | limits |
|---|---|---|
| `vllm` | `cpu: 4`, `memory: 4Gi` | `memory: 6Gi` |
| `model-downloader` | `cpu: 250m`, `memory: 256Mi` | `memory: 1Gi` |
| `bench` (отдельный под) | `cpu: 500m`, `memory: 512Mi` | `cpu: 1`, `memory: 2Gi` |

Настройки vLLM:

| Параметр | Значение |
|---|---|
| `VLLM_CPU_KVCACHE_SPACE` | 1 ГиБ, это 87 296 токенов KV-кэша |
| `max-model-len` | 3072 |
| `max-num-seqs` | 16 |
| `max-num-batched-tokens` | 4096 |
| `/dev/shm` | `emptyDir` в памяти, до 2Gi, засчитывается в лимит памяти контейнера |

Пробы контейнера vLLM:

| Проба | Таймаут | Порог |
|---|---|---|
| startup | 1 с | 60 попыток раз в 10 с, до 10 минут на старт |
| readiness | 5 с | 3 попытки раз в 10 с |
| liveness | 10 с | 6 попыток раз в 20 с, под перезапускается только после 2 минут без ответа |

Время:

| Событие | Длительность |
|---|---|
| Первая загрузка модели (около 1 ГБ) | от 1 до 3 минут |
| initContainer при модели на PVC | около 3 секунд |
| Старт vLLM, включая `torch.compile` | около 2,5 минут |
| Ответ на короткий запрос (`max_tokens` 20) | около 4 или 5 секунд |
| Нагрузочный тест (`make bench`) | около 40 минут |

Лимит CPU у vLLM не задан специально. CFS-квота в Kubernetes даёт троттлинг, а инференс на CPU и так упирается в число ядер.

С `VLLM_CPU_OMP_THREADS_BIND=auto` vLLM привязывает потоки вычислений к физическим ядрам и одно ядро оставляет под служебные задачи. На стенде это три ядра (`core ids=[1, 3, 5]` в логе старта). Это главное ограничение производительности.

Бюджет minikube меньше памяти WSL. Если vLLM превысит лимит, Kubernetes убьёт только под (`OOMKilled`), а WSL и Docker останутся работать.

## Подводные камни

**`VLLM_PORT 'tcp://...' appears to be a URI`.** Kubernetes добавляет в под переменные окружения для каждого Service в namespace. Для сервиса `vllm` появляется `VLLM_PORT=tcp://10.x.x.x:8000`. Это имя совпадает с настройкой самого vLLM, и движок падает при старте. Решение: `enableServiceLinks: false` в спецификации пода. Сервис доступен по DNS-имени, переменные не нужны. По той же причине эта настройка стоит и у пода `bench`: в нём тоже запускается vLLM.

**Нехватка памяти в WSL.** С настройками по умолчанию (`memory=12GB` из 16, KV-кэш 2 ГиБ, minikube без явного лимита) на пике старта vLLM упала вся виртуальная машина WSL вместе с Docker Desktop. Помогли честный бюджет minikube (меньше памяти WSL), swap для WSL и KV-кэш 1 ГиБ.

**`get_mempolicy: Operation not permitted` в логе vLLM.** vLLM пытается привязать память к NUMA-узлу, а `seccomp RuntimeDefault` и `drop: ALL` это запрещают. На машине с одним NUMA-узлом это ни на что не влияет. Это осознанная цена за ограничения безопасности.

**Пробы под нагрузкой.** По умолчанию проба ждёт ответа 1 секунду. Когда CPU полностью занят генерацией, `/health` может отвечать дольше. Тогда под помечается неготовым, Service перестаёт направлять на него запросы, а liveness может перезапустить его посреди работы. Поэтому таймауты readiness и liveness увеличены, а liveness срабатывает только после 2 минут без ответа.

**Secret с хешем в имени.** `secretGenerator` добавляет к имени Secret хеш содержимого (`llm-secrets-xxxxxxxxxx`). Манифест, применённый через `kubectl apply -f`, ссылался бы на несуществующий `llm-secrets`. Поэтому под `bench` разворачивается через свой overlay, и kustomize подставляет правильное имя.

**Обновление образа в minikube.** С тем же тегом и `imagePullPolicy: IfNotPresent` под может продолжить работать на старом образе. После правок надо поднимать тег (`make build load VERSION=0.1.1`) и менять `newTag` в `k8s/overlays/minikube/kustomization.yaml` и `bench/kustomization.yaml`.

## Известные ограничения

* Кэш `torch.compile` хранится в `emptyDir`, поэтому после каждого рестарта пода компиляция повторяется, это около 2 минут.
* Если под убить посреди загрузки, временная папка `.tmp-*` останется на PVC. Следующий запуск создаст новую и скачает модель заново.
* Тесты работают через `kubectl port-forward` на `localhost:8000`, его нужно держать открытым в отдельном терминале.
* Python-пакеты и базовые образы закреплены, а системные пакеты из `apt-get` (`g++`, `libtcmalloc-minimal4`, `libnuma1`) нет. Они берутся в той версии, которая есть в Debian bookworm на момент сборки.
* Нагрузочный тест сделан одним прогоном на ноутбуке. Клиент и сервер делят одни и те же ядра, поэтому цифры показывают тенденции, а не предельную производительность.
