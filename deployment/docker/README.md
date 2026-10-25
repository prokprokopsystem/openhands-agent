# Производный образ OpenHands Canvas с постоянными PDF-инструментами

Раздел посвящён этапу DEC-026: постоянный набор чтения/обработки/создания PDF в производном
образе от фактически работающего `openhands-agent-canvas-ssh:1.6.1-restored`. См. также
`deployment/README.md`, раздел «Постоянные PDF-инструменты и совместная проверка QET/PDF».

## Что добавляется

- Системные пакеты (Debian 13, зафиксированные версии):
  - `poppler-utils` 25.03.0-5+deb13u2 — pdfinfo, pdftotext, pdftoppm/pdftocairo, pdfimages;
  - `qpdf` 12.2.0-1 — структурная проверка и операции с PDF;
  - `tesseract-ocr` 5.5.0-1+b1 + `tesseract-ocr-eng/pol/rus` 1:4.1.0-2 — OCR;
  - `fonts-dejavu-core` 2.37-8, `fonts-noto-core` 20201225-2 — кириллица и польские диакритики.
- Изолированное Python-окружение `/opt/pdf-tools/venv` (не подменяет системный `python3`,
  не попадает в PATH backend):
  - `PyMuPDF` 1.26.4 — рендер страниц/фрагментов, текст с координатами, изображения;
  - `pypdf` 6.21.2 — страницы, объединение/разделение/поворот, метаданные, формы;
  - `reportlab` 5.1.0 — создание PDF (со шрифтами DejaVu для кириллицы/польского).

Вызов Python-инструментов: `/opt/pdf-tools/venv/bin/python` (например,
`/opt/pdf-tools/venv/bin/python -c "import pymupdf"`). Системный `python3` не изменяется.

## База и совместимость

- База — работающий образ `openhands-agent-canvas-ssh:1.6.1-restored`
  (ID `sha256:293042314e9e535e63c2c65f8df591e3eb545c5d781e402efb799b8a2a5d5a21`).
  До сборки сверить с текущим контейнером: `docker inspect -f '{{.Image}}' openhands-agent`.
- Версии Canvas/SDK, модель и профиль не меняются. ENTRYPOINT/CMD/WORKDIR/USER наследуются.
- Build context содержит только `Dockerfile.pdf-tools`; config, gh, secrets и проекты в образ не попадают.

## Сборка (без sudo, docker-группа)

```bash
mkdir -p /srv/openhands-agent/build-pdf-tools
cp deployment/docker/Dockerfile.pdf-tools /srv/openhands-agent/build-pdf-tools/
cd /srv/openhands-agent/build-pdf-tools
docker build -f Dockerfile.pdf-tools -t openhands-agent-canvas-ssh:1.6.1-restored-pdftools .
docker image inspect openhands-agent-canvas-ssh:1.6.1-restored-pdftools --format '{{.Id}}'
```

Сборку можно выполнять при работающем Canvas: она не трогает действующий контейнер.

## Функциональная проверка (одноразовый контейнер)

```bash
docker run --rm --entrypoint bash openhands-agent-canvas-ssh:1.6.1-restored-pdftools -c '
  set -euo pipefail
  T=$(mktemp -d); trap "rm -rf \"$T\"" EXIT; cd "$T"
  /opt/pdf-tools/venv/bin/python - <<PY
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
pdfmetrics.registerFont(TTFont("DejaVu", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"))
c = canvas.Canvas("t.pdf")
for text in ["P04 Y1 — Отчёт — ąćęłńóśźż", "Страница 2"]:
    c.setFont("DejaVu", 20)
    c.drawString(72, 700, text)
    c.showPage()
c.save()
import pymupdf
from pypdf import PdfReader, PdfWriter
d = pymupdf.open("t.pdf")
d[0].get_pixmap(dpi=150).save("page.png")
d[0].get_pixmap(dpi=200, clip=pymupdf.Rect(60, 100, 550, 200)).save("clip.png")
assert "P04 Y1" in d[0].get_text()
r = PdfReader("t.pdf")
w = PdfWriter()
w.append(r)
w.append(r, pages=[0])
w.write("merged.pdf")
assert len(PdfReader("merged.pdf").pages) == 3
w = PdfWriter()
w.add_page(r.pages[0].rotate(90))
w.write("split-rotated.pdf")
assert len(PdfReader("split-rotated.pdf").pages) == 1
assert PdfReader("split-rotated.pdf").pages[0].rotation == 90
PY
  pdftotext t.pdf text.txt
  grep -F "P04 Y1" text.txt
  qpdf --check t.pdf
  qpdf --check merged.pdf
  qpdf --check split-rotated.pdf
  tesseract page.png ocr -l eng+pol+rus
  grep -F "P04" ocr.txt
'
```

Успешный `import` или `--version` не считается функциональной проверкой: критерий — реальный
рендер, извлечённый текст, OCR и проходящий `qpdf --check`.

## Применение и откат (нужен root — одна команда владельцу)

Скрипт `deployment/docker/switch-pdf-image.sh` (на хосте — `/srv/openhands-agent/build-pdf-tools/switch-pdf-image.sh`):

```bash
sudo bash /srv/openhands-agent/build-pdf-tools/switch-pdf-image.sh
```

Исправлено 25 октября: скрипт сохраняет точные исходные байты Compose в памяти процесса, без .bak-копий и отдельных lockfiles. До переключения проверяет точные ID обоих образов и наследование Entrypoint/Cmd/User/WorkingDir. После правки сравнивает разобранную конфигурацию: разрешено изменение только image сервиса openhands.

Успех означает успешный systemctl restart, новый ID контейнера, точный ожидаемый image ID и running/healthy. Старый healthy-контейнер успехом не считается. При исключении возвращает исходные байты и проверяет healthy прежнего image; если проверка отката не удалась, прямо сообщает это. Внезапное завершение процесса/питания может потерять сохранённые в памяти байты; прежний образ и версия Compose в Git остаются основой ручного восстановления. Дополнительные архивы не создаются.

Перед запуском серверная копия скрипта должна совпадать с исправленной версией этого PR. Более раннюю копию с .bak не запускать.

Проверки без Docker/systemd, включая ошибки Compose/restart/health и откат:
```bash
python3 deployment/docker/tests/test_switch_pdf_image.py
```

Фактический серверный запуск исправленной версии пока не выполнен. После него отдельно проверить рабочие PDF-tools, SSH и GitHub.

Другие сервисы (AMNESIA, Nextcloud, Telegram-gateway, firewall, хостовый Docker) не затрагиваются.
Старый образ `openhands-agent-canvas-ssh:1.6.1-restored` не удаляется — он остаётся точкой отката.

## Фактический результат (24 октября 2026)

Статусы разделены: **собрано** и **проверено в одноразовом контейнере** — да; **применено к живому Canvas** — ожидает sudo-перезапуска.

- **Образ собран:** `openhands-agent-canvas-ssh:1.6.1-restored-pdftools`,
  Id `sha256:40b7a43da65f14b5de79959b82544bec1d2cde4fd4535e9f0ed51e820778b188`,
  +2 слоя от базы, все бинарники (`pdfinfo/pdftotext/pdftoppm/pdftocairo/pdfimages/qpdf/tesseract`) и языки tesseract `eng/pol/rus` на месте.
- **Функциональные пробы (пользователь `openhands`, одноразовый контейнер) — ПРОЙДЕНО:** создание 2-страничного PDF с кириллицей/польским (reportlab + DejaVu), `pdftotext`, текст и рендер страницы/фрагмента (PyMuPDF), merge/split/rotate (pypdf), `qpdf --check`, OCR (распознаны `P04 Y1`).
- **Реальный рендер `лист 07.pdf`** тем же образом и визуальное чтение моделью через Canvas — **ПРОЙДЕНО**.
- **Первая цепь Y1 (QET + визуальный PDF + MASTER) — СОВПАДАЕТ.** Доказательства:
  - QET (реальные element UUID + terminal endpoints, восстановленная геометрия): `A1 id8 (CIO 100.00) ↔ X6:1 ↔ Y1`; `Y1 ↔ X6:6 ↔ arrow(e0f9eb9)=0 V`; `A1 COM id29 ↔ arrow(eec4f86)=+24 V`; перемычка X6 только `6↔7↔8↔9↔10`.
  - PDF (рендер фрагментов): `A1 Omron CP2E-N40DT1-D DIGITAL OUTPUTS (DO)`; вывод `100.00` (крайний левый) уходит вниз к `X6:1`; `Y1` = SMC SY3120 `C1 ACTIVE`; `FROM SHEET 04 / X8 +24 V` → COM-шина A1, `0 V` → вниз к X6-6.
  - MASTER (`P04 — MASTER … .xlsx`, вкладка IO): `100.00 | Y1 | CENTER PRODUCT / C1 ACTIVE | A1 DO → X6:1 → Y1`; `X6:1 → Y1 coil +`, возврат `X6:6 → X8/0V`.
  - **Итог:** `A1 DO 100.00 → X6:1 → Y1`, возврат `Y1 → X6:6 → 0 V`; питание COM → +24 V от X8:7.
- **Устаревшие скрытые имена символов:** элемент A1 в QET имеет тип/текст `a1omron.elmt` / `Delta AX-308EA0MA1P` / `Delta_AX3`, но актуально по PDF и MASTER — `Omron CP2E-N40DT1-D`. Скрытые имена не использовать для идентификации аппарата.
- **Применение к Canvas — ВЫПОЛНЕНО (25 октября).** Владелец запустил `switch-pdf-image.sh` → SUCCESS. Новый контейнер `6ae48094671a`, образ `…-pdftools` = `sha256:40b7a43…`, `healthy` (`StartedAt 2026-10-25T02:17:56Z`); прежний `sha256:293042…` сохранён для отката. В живом контейнере проверены: PDF-инструменты от `openhands`, SSH mini-server, GitHub и приватный репозиторий, профиль DeepSeek, маунты и материалы P04 (`LIVE_FULL_PIPELINE_OK`, `LIVE_REAL_SHEET07_OK`).


### Отображение схемы в Canvas — замечание 25 октября

В отчёте агента заявлено визуальное чтение PDF. Однако на переданном скриншоте справа открыт .openhands/memory/MEMORY.md с неработающей встроенной ссылкой на P04-training/renders/лист07_full.png. Это не показ схемы пользователю. Открыть реальный PNG напрямую через доступный Canvas preview/file viewer по проверенному пути и убедиться, что пользователь видит страницу. Не создавать ещё один служебный документ вместо картинки и не считать сломанную ссылку подтверждённым preview. Наблюдение не доказывает, что агент сам не видел изображение ранее; оно фиксирует неполадку выдачи результата пользователю.

**Исправлено (25 октября):** причина — PNG лежал в `/projects/…`, вне рабочего каталога Canvas (`…/workspace/project/84da921…`), поэтому путь не разрешался и справа оставался MEMORY.md. Рендер скопирован в рабочий каталог Canvas и открыт напрямую по `renders/лист07_full.png` (настоящий лист 07, 2339×1653). Схема показана пользователю.
