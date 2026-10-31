# memory-pilot — прототип долговременной памяти (M2)

Изолированный прототип хранения и поиска для пилота памяти. Работает **как
библиотека**: без службы, без порта, без изменений работающего Canvas.
Автоматическая память в чатах здесь НЕ реализована — это следующий этап M3.

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
