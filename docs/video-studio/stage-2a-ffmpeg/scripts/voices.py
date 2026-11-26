#!/usr/bin/env python3
"""Группировка речи в реплики + разделение голосов по F0/спектру."""
import array, math, sys, wave

WAV = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tokyo/golos.wav"
FRAME_MS, HOP_MS = 20, 10

with wave.open(WAV, "rb") as w:
    rate, ch, n = w.getframerate(), w.getnchannels(), w.getnframes()
    raw = w.readframes(n)
samples = array.array("h")
samples.frombytes(raw)
if ch == 2:
    samples = array.array("h", samples[0::2])
del raw

frame = int(rate * FRAME_MS / 1000)
hop = int(rate * HOP_MS / 1000)
w_len = int(rate * 0.04)
lag_min, lag_max = int(rate / 400), int(rate / 60)


def hp_energy(seg, fc=900.0):
    """Грубая энергия выше fc через разностный фильтр (усиление ВЧ)."""
    a = math.exp(-2 * math.pi * fc / rate)
    y_prev = 0.0
    x_prev = 0.0
    acc = 0.0
    for v in seg:
        y = a * (y_prev + v - x_prev)
        x_prev = v
        y_prev = y
        acc += y * y
    return acc


stats = []
t = 0
while t + frame <= len(samples):
    seg = samples[t:t + frame]
    s = sum(v * v for v in seg)
    rms = math.sqrt(s / len(seg)) / 32768.0
    x = seg[:w_len]
    mean = sum(x) / len(x)
    x = [v - mean for v in x]
    e0 = sum(v * v for v in x) or 1.0
    best, bestlag = 0.0, 0
    for lag in range(lag_min, min(lag_max, len(x) // 2)):
        acc = 0.0
        for i in range(0, len(x) - lag):
            acc += x[i] * x[i + lag]
        r = acc / e0
        if r > best:
            best, bestlag = r, lag
    f0 = rate / bestlag if bestlag and best > 0.35 else 0.0
    hf = hp_energy(seg)
    stats.append((t / rate, rms, f0, best, hf / (s or 1)))
    t += hop

db = [20 * math.log10(max(s_[1], 1e-6)) for s_ in stats]
peak = max(db)
thr = max(peak - 30, -50)
flags = [d > thr for d in db]


def fill(fl, gap, val):
    out = fl[:]
    i = 0
    while i < len(out):
        if out[i] != val:
            j = i
            while j < len(out) and out[j] != val:
                j += 1
            if j - i <= gap:
                for k in range(i, j):
                    out[k] = val
            i = j
        else:
            i += 1
    return out


flags = fill(flags, int(250 / HOP_MS), True)
flags = fill(flags, int(120 / HOP_MS), False)

# реплики: склеиваем сегменты, если пауза < 0.60 с
utts = []
i = 0
while i < len(flags):
    if flags[i]:
        j = i
        gap_start = None
        while j < len(flags):
            if flags[j]:
                gap_start = None
                j += 1
            else:
                if gap_start is None:
                    gap_start = j
                if (j - gap_start) * HOP_MS / 1000 > 0.60:
                    break
                j += 1
        end_idx = gap_start if gap_start is not None else j
        rows = stats[i:end_idx]
        voiced = [r[2] for r in rows if r[2] > 0 and r[3] > 0.35]
        if rows and len(voiced) >= 3:
            f0s = sorted(voiced)
            utts.append(dict(
                t0=rows[0][0], t1=stats[end_idx - 1][0] + FRAME_MS / 1000,
                f0=f0s[len(f0s) // 2], f0lo=f0s[len(f0s) // 10], f0hi=f0s[-len(f0s) // 10 or -1],
                hf=sum(r[4] for r in rows) / len(rows),
                db=20 * math.log10(max(sum(r[1] for r in rows) / len(rows), 1e-6)),
                nv=len(voiced)))
        i = max(end_idx, i + 1)
    else:
        i += 1

print(f"{'#':>2} {'начало':>7} {'конец':>7} {'длит':>6} {'F0med':>6} {'F0 10-90%':>13} {'HF':>6} {'dB':>6}")
for k, u in enumerate(utts, 1):
    print(f"{k:2} {u['t0']:7.2f} {u['t1']:7.2f} {u['t1'] - u['t0']:6.2f} {u['f0']:6.1f} "
          f"{u['f0lo']:6.1f}-{u['f0hi']:6.1f} {u['hf']:6.3f} {u['db']:6.1f}")

f0s = [u['f0'] for u in utts]
print(f"\nF0 по репликам: min={min(f0s):.1f} max={max(f0s):.1f}")

# k-means (2) по log F0
logs = [math.log(u['f0']) for u in utts]
c1, c2 = min(logs), max(logs)
for _ in range(50):
    g1 = [x for x in logs if abs(x - c1) <= abs(x - c2)]
    g2 = [x for x in logs if abs(x - c1) > abs(x - c2)]
    if not g1 or not g2:
        break
    n1, n2 = sum(g1) / len(g1), sum(g2) / len(g2)
    if abs(n1 - c1) < 1e-6 and abs(n2 - c2) < 1e-6:
        break
    c1, c2 = n1, n2
print(f"кластеры F0: {math.exp(c1):.1f} Гц (n={len(g1)}) и {math.exp(c2):.1f} Гц (n={len(g2)})")
for k, u in enumerate(utts, 1):
    grp = 1 if abs(math.log(u['f0']) - c1) <= abs(math.log(u['f0']) - c2) else 2
    u['grp'] = grp
seq = " ".join(f"{u['grp']}" for u in utts)
print("последовательность голосов:", seq)
for grp in (1, 2):
    tot = sum(u['t1'] - u['t0'] for u in utts if u['grp'] == grp)
    print(f"  голос {grp}: {sum(1 for u in utts if u['grp'] == grp)} реплик, {tot:.2f} с")
