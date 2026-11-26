#!/usr/bin/env python3
"""Профиль движения по кадрам: где Вася двигается, где кадр спокоен."""
import subprocess
import sys
import imageio_ffmpeg

FF = imageio_ffmpeg.get_ffmpeg_exe()


def motion(path):
    p = subprocess.run(
        [FF, "-hide_banner", "-i", path, "-vf",
         "tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG",
         "-an", "-f", "null", "-"],
        capture_output=True, text=True)
    vals = []
    for line in p.stderr.splitlines():
        if "YAVG=" in line:
            vals.append(float(line.split("YAVG=")[1].split()[0]))
    return vals


def curve(vals, fps=24.0, win=0.25):
    n = int(round(fps * win))
    out = []
    for i in range(0, len(vals) - n, n):
        chunk = vals[i:i + n]
        out.append((i / fps, sum(chunk) / len(chunk), max(chunk)))
    return out


for path in sys.argv[1:]:
    v = motion(path)
    print(f"=== {path}  кадров {len(v)} = {len(v) / 24:.2f} с")
    med = sorted(v)[len(v) // 2]
    mx = max(v)
    print(f"    медиана {med:.3f}  максимум {mx:.3f}")
    c = curve(v)
    line = " ".join(f"{a:5.1f}s:{m:5.2f}" for a, m, _ in c)
    for i in range(0, len(c), 4):
        print("   ", " ".join(f"{a:5.1f}:{m:5.2f}" for a, m, _ in c[i:i + 4]))
    peaks = [(a, m) for a, m, _ in c if m > med * 2.0]
    print("    всплески >2x медианы:", ", ".join(f"{a:.1f}s({m:.2f})" for a, m in peaks) or "нет")
    calm = [(a, m) for a, m, _ in c if m < med * 0.5]
    print("    спокойные:", ", ".join(f"{a:.1f}s" for a, m in calm) or "нет")
    print()
