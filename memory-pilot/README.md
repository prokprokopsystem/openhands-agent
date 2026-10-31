# memory-pilot — прототип долговременной памяти (M2)

Изолированный прототип хранения и поиска для пилота памяти. Работает **как
библиотека**: без службы, без порта, без изменений работающего Canvas.
Подключение к чатам идёт штатными хуками OpenHands — плагин `plugin/`;
ограниченная автоматическая запись включена только для тестового проекта
(этап 1), см. [docs/Память-пилот-2026-10-31.md](../docs/Память-пилот-2026-10-31.md).

Результаты, ограничения и замеры: [docs/Память-M2-2026-10-31.md](../docs/Память-M2-2026-10-31.md).

## Что проверяется

Только механизм: хранение, точный и смысловой поиск, ссылки на источники,
история исправления фактов, чтение индекса новым процессом.

## Состав стека

| Слой | Значение |
|---|---|
| Mem0 OSS | 2.2.1 (в отдельном venv) |
| Эмбеддинги | fastembed 0.9.1, `paraphrase-multilingual-MiniLM-L12-v2`, локальный ONNX |
| Хранилище | embedded Qdrant (файловый, без сервера) |
| LLM | DeepSeek, но **не вызывается** (`infer=False`) |
| Телеметрия | `MEM0_TELEMETRY=False` до первого запуска |

## Воспроизведение

```bash
mkdir -p /projects/memory-pilot && cd /projects/memory-pilot
python3 -m venv venv
export MEM0_TELEMETRY=False
./venv/bin/pip install -r <repo>/memory-pilot/requirements.lock

cp <repo>/memory-pilot/scripts/*.py scripts/
./venv/bin/python scripts/build_corpus.py     # корпус из двух проектов
./venv/bin/python scripts/ingest.py           # загрузка, infer=False, идемпотентно
./venv/bin/python scripts/tests.py            # 8 приёмочных проверок
./venv/bin/python scripts/verify_fresh.py     # чтение индекса новым процессом
./venv/bin/python scripts/bench.py            # замеры RAM/диска/скорости
```

Порядок важен: `verify_fresh.py` запускается **после** завершения предыдущего
процесса — embedded Qdrant держит эксклюзивную блокировку каталога.

## Безопасность

- Секреты, токены и персональные данные в корпус не попадают: перед копированием
  выполняется поиск по шаблонам ключей/токенов/почты, внутренние IP маскируются.
- Источники — публичные документы двух проектов, копии обезличены.
- Действующие Canvas, профили, `settings.json`, compose, systemd, SSH, backup,
  AMNESIA и Nextcloud не изменяются.

## Хуки (M3, этап 1)

| Событие | Команда | Назначение |
|---|---|---|
| `user_prompt_submit` | `hook_recall.py` | поиск по корпусу + фрагменты stage-1 в контекст |
| `stop` | `hook_capture.py` | реплики разговора → очередь, без LLM |
| `session_end` | `hook_write.py` | запись очереди закрывающегося разговора |
| `session_start` | `hook_write.py --sweep` | запись всех накопленных очередей |

Запись включается только для проектов из `stage1/config.json`; остальные чаты
остаются read-only. Выключение — `"enabled": false` в этом файле. Актуальность
решения всегда берётся из канонического документа проекта, а не из памяти.

```bash
./venv/bin/python scripts/write_selftest.py    # offline: 24 проверки
./venv/bin/python scripts/live_e2e.py state    # очередь, аудит записи, документ
```

Порядок и замеры — в разделе «Автоматическая запись, этап 1» документа пилота.
