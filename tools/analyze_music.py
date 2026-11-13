"""诊断：看录屏音频的响度结构 + 循环周期（一次性分析脚本）。

用法：python tools/analyze_music.py <wav>
"""

from __future__ import annotations

import sys
import wave
from pathlib import Path

import numpy as np

SR = 48000


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        ch, sw, sr = w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(w.getnframes())
    d = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if ch > 1:
        d = d.reshape(-1, ch).mean(axis=1)
    if sr != SR:
        n = int(round(d.size * SR / sr))
        d = np.interp(np.linspace(0, 1, n, endpoint=False), np.linspace(0, 1, d.size, endpoint=False), d)
    return d


def main() -> None:
    x = read_wav(Path(sys.argv[1]))
    dur = x.size / SR
    print(f"duration={dur:.2f}s peak={np.abs(x).max():.3f}")

    # 1 s 分辨率响度
    step = SR
    prof = []
    for i in range(0, x.size - step, step):
        seg = x[i : i + step]
        prof.append(20 * np.log10(max(np.sqrt((seg ** 2).mean()), 1e-9)))
    print("\nper-second dB:")
    for i in range(0, len(prof), 12):
        row = " ".join(f"{i+j:3d}:{prof[i+j]:6.1f}" for j in range(min(12, len(prof) - i)))
        print("  " + row)

    # 找起音
    peak = np.abs(x).max()
    for db in (-40, -45, -50, -55):
        thr = peak * 10 ** (db / 20)
        idx = np.flatnonzero(np.abs(x) > thr)
        print(f"first sample above {db} dB: {idx[0]/SR:.3f}s" if idx.size else f"{db}dB: none")

    # 循环周期：模板 2 s，从 6.0 s 起，扫 8..80 s
    start = int(float(sys.argv[2]) * SR) if len(sys.argv) > 2 else 0
    tpl = x[start : start + 2 * SR]
    tpl_e = float((tpl ** 2).sum())
    best = []
    for T in np.arange(8.0, 80.0, 0.02):
        i = start + int(round(T * SR))
        if i + tpl.size > x.size:
            break
        seg = x[i : i + tpl.size]
        num = float((seg * tpl).sum())
        den = np.sqrt(max(float((seg ** 2).sum()), 1e-12) * tpl_e)
        best.append((num / den, round(float(T), 2)))
    best.sort(reverse=True)
    print("\ntop loop candidates (score, T):")
    seen = []
    for s, t in best[:40]:
        if all(abs(t - u) > 0.5 for u in seen):
            seen.append(t)
            print(f"  T={t:7.2f}s  score={s:.3f}")
        if len(seen) >= 8:
            break


if __name__ == "__main__":
    main()
