"""生成主界面 BGM（2.0）：循环氛围垫，很轻，不抢戏。

设计：24 s 无缝循环，Dm9 → Bbmaj7 → Gm7 → A7sus 四个和弦轮换，
每段 6 s，低频 pad + 风噪 + 极弱的钟点，首尾交叉淡化保证循环无缝。

输出：assets/audio/title_loop.wav（48 kHz / 16 bit / 立体声）
运行：python tools/make_title_audio.py
"""

from __future__ import annotations

import math
import wave
from pathlib import Path

import numpy as np

SR = 48000
BAR = 6.0
BARS = 4
DUR = BAR * BARS
XFADE = 1.2
OUT = Path(__file__).resolve().parent.parent / "assets" / "audio" / "title_loop.wav"

rng = np.random.default_rng(20261114)


def midi(note: float) -> float:
    return 440.0 * 2.0 ** ((note - 69.0) / 12.0)


# Dm9 / Bbmaj7 / Gm7 / A7sus（MIDI 音高）
CHORDS = [
    [38, 45, 53, 57, 60, 64],   # Dm9
    [34, 41, 50, 53, 57, 60],   # Bbmaj7
    [31, 38, 46, 50, 53, 58],   # Gm7
    [33, 40, 48, 52, 55, 62],   # A7sus
]


def lowpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    a = math.exp(-2.0 * math.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(x.size):
        acc = (1.0 - a) * x[i] + a * acc
        y[i] = acc
    return y


def main() -> None:
    total = int(DUR * SR)
    buf = np.zeros(total, dtype=np.float64)

    for bar, notes in enumerate(CHORDS):
        start = int(bar * BAR * SR)
        n = int(BAR * SR)
        t = np.arange(n) / SR
        seg = np.zeros(n, dtype=np.float64)
        for note in notes:
            f = midi(note)
            for det in (-0.08, 0.08):
                ph = 2.0 * math.pi * f * (1.0 + det / 100.0) * t + rng.uniform(0, 6.28)
                seg += (2.0 * ((ph / (2.0 * math.pi)) % 1.0) - 1.0) * (0.5 / len(notes))
        seg = lowpass(seg, 1200.0)
        # 每小节的呼吸包络（起音 1.2 s，尾巴 2.4 s）
        env = np.minimum(np.clip(t / 1.2, 0.0, 1.0), np.clip((BAR - t) / 2.4, 0.0, 1.0))
        buf[start:start + n] += seg * env * 0.5

    # 风噪：低通过滤的粉噪，缓慢起伏
    t_all = np.arange(total) / SR
    noise = lowpass(rng.normal(0.0, 1.0, total), 380.0)
    noise /= max(np.abs(noise).max(), 1e-9)
    swell = 0.55 + 0.45 * np.sin(2.0 * math.pi * t_all / DUR * 2.0)
    buf += noise * swell * 0.16

    # 极弱的钟点（每 6 s 一下，制造时间感）
    for bar in range(BARS):
        start = int(bar * BAR * SR) + int(0.6 * SR)
        n = int(2.4 * SR)
        t = np.arange(n) / SR
        bell = np.zeros(n, dtype=np.float64)
        for f0, amp, decay in ((midi(81), 0.5, 1.6), (midi(88), 0.22, 2.4)):
            bell += np.sin(2.0 * math.pi * f0 * t) * amp * np.exp(-t * decay)
        end = min(start + n, total)
        buf[start:end] += bell[: end - start] * 0.05

    # 交叉淡化首尾，让循环无缝
    xf = int(XFADE * SR)
    head = buf[:xf].copy()
    tail = buf[-xf:].copy()
    ramp = np.linspace(0.0, 1.0, xf)
    buf[:xf] = head * ramp + tail * (1.0 - ramp)
    buf = buf[: total - xf]

    # 立体声：轻微的时间差制造宽度
    delay = int(0.013 * SR)
    left = buf.copy()
    right = np.concatenate([np.zeros(delay), buf[:-delay]])
    st = np.stack([left, right], axis=1)
    st /= max(np.abs(st).max(), 1e-9)
    st *= 0.62
    st = np.tanh(st * 1.05) * 0.9

    pcm = (np.clip(st, -1.0, 1.0) * 32767.0).astype("<i2")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {OUT}  {buf.size / SR:.2f}s loop  peak {20*math.log10(max(np.abs(st).max(),1e-9)):.2f} dBFS")


if __name__ == "__main__":
    main()
