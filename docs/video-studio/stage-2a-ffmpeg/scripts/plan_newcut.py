#!/usr/bin/env python3
"""План нового фильма family-newcut-v1 под полный трек 316.108 с.

Отличия от плана v1:
  - новый независимый отбор (другой seed), широкий охват всего архива;
  - нет прямых склеек: у каждого стыка crossfade 0.5-0.8 с;
  - каждой видеосцене назначается режим кадра:
      fill  - кроп до 9:16, если движение сцены укладывается в центральную
              полосу (заполняет весь экран);
      fit   - иначе квадрат по ширине кадра на затемнённой подложке, чтобы
              не срезать людей и жесты.

    plan_newcut.py inventory.csv motion.csv plan.csv --target 316.108
"""
import argparse
import csv
import random

SEED = 20261122
TARGET_VIDEOS = 66
TARGET_PHOTOS = 16
XFADE_CHOICES = (0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8)
CENTRAL_BAND = 0.56          # ширина кадра 9:16 относительно квадрата


def load(path):
    circles, longs, photos = [], [], []
    with open(path) as f:
        for r in csv.DictReader(f):
            try:
                dur = float(r["duration"] or 0)
                w, h = int(r["width"] or 0), int(r["height"] or 0)
            except ValueError:
                continue
            if w == 0 or h == 0:
                continue
            item = {"file": r["file"], "dur": dur, "w": w, "h": h}
            if r["kind"] == "image":
                if r["ext"] == "jpg":
                    photos.append(dict(item, kind="photo"))
            elif r["kind"] == "video" and dur > 0.5:
                if w == h:
                    circles.append(dict(item, kind="circle"))
                else:
                    longs.append(dict(item, kind="long"))
    for lst in (circles, longs, photos):
        lst.sort(key=lambda x: x["file"])
    return circles, longs, photos


def load_motion(path):
    """x0, x1, y0, y1 движения в долях кадра."""
    out = {}
    try:
        with open(path) as f:
            for r in csv.DictReader(f):
                out[r["file"]] = tuple(float(r[k]) for k in ("x0", "x1", "y0", "y1"))
    except FileNotFoundError:
        pass
    return out


def pick_spread(items, n, rng, runs=True):
    """Равномерный охват с короткими сериями: не только край архива."""
    if len(items) <= n:
        return items[:]
    step = len(items) / n
    out, used = [], set()
    for k in range(n):
        base = int(k * step)
        if runs and rng.random() < 0.3 and k + 1 < n:
            for off in (0, 1, 2):
                idx = base + off
                if idx < len(items) and idx not in used:
                    used.add(idx)
                    out.append(items[idx])
                    break
        else:
            idx = min(len(items) - 1, base + rng.randrange(max(1, int(step))))
            while idx in used and idx < len(items) - 1:
                idx += 1
            used.add(idx)
            out.append(items[idx])
    # обрезаем до n, сохраняя порядок
    return out[:n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inventory")
    ap.add_argument("motion")
    ap.add_argument("out")
    ap.add_argument("--target", type=float, default=316.108)
    a = ap.parse_args()

    circles, longs, photos = load(a.inventory)
    motion = load_motion(a.motion)
    rng = random.Random(SEED)

    n_long = min(3, len(longs))
    n_circle = TARGET_VIDEOS - n_long

    chosen = [dict(c, kind="circle") for c in pick_spread(circles, n_circle, rng)]
    chosen += [dict(l, kind="long") for l in pick_spread(longs, n_long, rng) if l["dur"] > 6]
    chosen.sort(key=lambda x: x["file"])

    # Длительности: спокойный темп, 3-6 с, редкие спокойные 6-7 с.
    for it in chosen:
        it["plan"] = round(rng.uniform(3.0, 5.2), 2)
        if rng.random() < 0.15:
            it["plan"] = round(rng.uniform(5.2, 6.4), 2)

    photos_pick = pick_spread(photos, TARGET_PHOTOS, rng, runs=False)
    photo_rows = [{"file": p["file"], "kind": "photo", "start": 0.0,
                   "dur": round(rng.uniform(5.2, 7.6), 2), "w": p["w"], "h": p["h"],
                   "mode": "static"} for p in photos_pick]

    video_rows = []
    for it in chosen:
        want = min(it["plan"], it["dur"] - 0.5)
        if want < 2.0:
            continue
        # окно подальше от начала: первые кадры часто размыты после нажатия
        latest = max(0.0, it["dur"] - want - 0.4)
        start = rng.uniform(0.25, 0.25 + latest * 0.5) if latest > 0.2 else 0.0
        start = round(min(start, latest), 3)
        mode = "fit"
        bb = motion.get(it["file"])
        if bb:
            x0, x1, y0, y1 = bb
            lo, hi = (1 - CENTRAL_BAND) / 2, 1 - (1 - CENTRAL_BAND) / 2
            if x0 >= lo - 0.02 and x1 <= hi + 0.02:
                mode = "fill"
        video_rows.append({"file": it["file"], "kind": it["kind"], "start": start,
                           "dur": round(want, 2), "w": it["w"], "h": it["h"],
                           "mode": mode})

    # Порядок: сцены в порядке архива, фото вклиниваются равномерно.
    seq = video_rows[:]
    gap = max(1, len(seq) // max(1, len(photo_rows)))
    for n, ph in enumerate(photo_rows):
        seq.insert(min(len(seq), (n + 1) * gap + n), ph)

    # Переходы: у всех стыков crossfade, без прямых склеек.
    for i, r in enumerate(seq):
        if i == 0:
            r["xfade"] = 0.0
            continue
        r["xfade"] = rng.choice(XFADE_CHOICES)
        # переход не должен съедать больше 40% более короткого соседа
        limit = min(r["dur"], seq[i-1]["dur"]) * 0.4
        r["xfade"] = round(min(r["xfade"], limit), 2)
        if r["xfade"] < 0.5:
            r["xfade"] = 0.5

    def total(rows):
        return sum(x["dur"] for x in rows) - sum(x["xfade"] for x in rows)

    # Подгонка под трек: масштабируем и зажимаем в разумные рамки, остаток
    # раздаём длинным планам. Без этого один клип может вылезти за 7 с.
    lo_v, hi_v = 2.6, 6.6
    lo_p, hi_p = 5.0, 8.2
    for _ in range(4):
        k = a.target / total(seq)
        for r in seq:
            r["dur"] = r["dur"] * k
            lo, hi = (lo_p, hi_p) if r["kind"] == "photo" else (lo_v, hi_v)
            r["dur"] = max(lo, min(hi, r["dur"]))
        # не даём перекрытиям вылезти за новые длины
        for i, r in enumerate(seq):
            if i and r["xfade"] > min(r["dur"], seq[i-1]["dur"]) * 0.4:
                r["xfade"] = max(0.5, round(min(r["dur"], seq[i-1]["dur"]) * 0.4, 2))
    for r in seq:
        r["dur"] = round(r["dur"], 3)
    # точный остаток — на планы, у которых есть запас
    for _ in range(200):
        delta = a.target - total(seq)
        if abs(delta) < 0.002:
            break
        step = delta / len(seq)
        for r in seq:
            lo, hi = (lo_p, hi_p) if r["kind"] == "photo" else (lo_v, hi_v)
            r["dur"] = round(max(lo, min(hi, r["dur"] + step)), 3)

    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["idx", "file", "kind", "start", "dur",
                                          "w", "h", "xfade", "mode"])
        w.writeheader()
        for n, r in enumerate(seq):
            w.writerow({"idx": n, **r})

    vids = [r for r in seq if r["kind"] != "photo"]
    phs = [r for r in seq if r["kind"] == "photo"]
    print(f"планов: {len(seq)} (видео {len(vids)}, фото {len(phs)})")
    print(f"длина: планы {sum(r['dur'] for r in seq):.2f} с, "
          f"перекрытия {sum(r['xfade'] for r in seq):.2f} с, итог {total(seq):.2f} с")
    print(f"видео: среднее {sum(r['dur'] for r in vids)/len(vids):.2f} с "
          f"({min(r['dur'] for r in vids):.2f}-{max(r['dur'] for r in vids):.2f})")
    print(f"фото: среднее {sum(r['dur'] for r in phs)/len(phs):.2f} с "
          f"({min(r['dur'] for r in phs):.2f}-{max(r['dur'] for r in phs):.2f})")
    print(f"режим fill: {sum(1 for r in vids if r['mode'] == 'fill')}, "
          f"fit: {sum(1 for r in vids if r['mode'] == 'fit')}")
    print(f"прямых склеек: {sum(1 for i, r in enumerate(seq) if i and not r['xfade'])}")
    long_files = sorted({r['file'] for r in vids if r['kind'] == 'long'})
    print(f"длинные видео: {long_files}")
    circ = [r["file"] for r in vids if r["kind"] == "circle"]
    order = sorted(c["file"] for c in circles)
    if circ:
        pos = sorted(order.index(f) for f in circ if f in order)
        print(f"кружки: {len(pos)} из {len(order)}, индексы {pos[0]}..{pos[-1]}")
        from collections import Counter
        print("по 10 сегментам:", dict(sorted(Counter(p * 10 // len(order) for p in pos).items())))


if __name__ == "__main__":
    main()
