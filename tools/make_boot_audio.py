"""生成启动动画 BGM（2.0 版界面）。

设计要点（对应 GDD 里的「前几秒节奏不快、音量不大，几秒后突然爆发」）：
    0.00 - 4.90 s  前奏：Dm(add9) 低频 pad + 环境风噪，音量 -30 dB → -16 dB 缓慢推升
    4.30 - 5.00 s  吸气：带通噪声 + 正弦上扫（riser），末尾急收
    5.00 s         IMPACT：白光爆发点（boot_intro.gd 的 IMPACT_TIME = 5.0）
    5.00 - 7.60 s  爆发：sub-drop + 明亮和弦 + 铃音，D 大调，持续衰减
    7.60 - 10.0 s  余响：pad 尾巴渐隐，方便直接接标题画面

输出：assets/audio/boot_theme.wav（48 kHz / 16 bit / 立体声）
运行：python tools/make_boot_audio.py
"""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

import numpy as np

SR = 48000
DUR = 10.0
IMPACT = 5.0
OUT = Path(__file__).resolve().parent.parent / "assets" / "audio" / "boot_theme.wav"

rng = np.random.default_rng(20261113)


def t_axis(dur: float, start: float = 0.0) -> np.ndarray:
    n = int(round(dur * SR))
    return start + np.arange(n) / SR


def env(t: np.ndarray, start: float, attack: float, hold: float, release: float) -> np.ndarray:
    """梯形包络（起音 / 保持 / 释放），返回 0..1。"""
    x = t - start
    a = np.clip(x / max(attack, 1e-6), 0.0, 1.0)
    r = np.clip(1.0 - (x - attack - hold) / max(release, 1e-6), 0.0, 1.0)
    return np.clip(np.minimum(a, np.where(x < attack + hold, 1.0, r)), 0.0, 1.0) * (x >= 0)


def lowpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    """一阶 IIR 低通（够用，避免 scipy 依赖）。"""
    a = math.exp(-2.0 * math.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(x.size):
        acc = (1.0 - a) * x[i] + a * acc
        y[i] = acc
    return y


def highpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    return x - lowpass(x, cutoff)


def bandpass(x: np.ndarray, lo: float, hi: float) -> np.ndarray:
    return highpass(lowpass(x, hi), lo)


def add(buf: np.ndarray, sig: np.ndarray, at: float, gain: float) -> None:
    i = int(round(at * SR))
    if i >= buf.size:
        return
    n = min(sig.size, buf.size - i)
    buf[i:i + n] += sig[:n] * gain


def midi(note: float) -> float:
    return 440.0 * 2.0 ** ((note - 69.0) / 12.0)


# ----------------------------- 前奏 pad -----------------------------

def make_pad() -> np.ndarray:
    t = t_axis(IMPACT + 0.6)
    # Dm(add9)：D2 A2 D3 E3 F3 A3
    voices = [(38, 0.55), (45, 0.40), (50, 0.30), (52, 0.16), (53, 0.22), (57, 0.14)]
    sig = np.zeros_like(t)
    for note, amp in voices:
        f = midi(note)
        # 每个音两根略微失谐的锯齿，靠低通变柔和
        for det in (-0.12, 0.12):
            ph = 2.0 * math.pi * f * (1.0 + det / 100.0) * t + rng.uniform(0, 6.28)
            saw = 2.0 * ((ph / (2.0 * math.pi)) % 1.0) - 1.0
            sig += saw * amp * 0.5
        # 轻微颤音，像风在推
        sig *= 1.0 + 0.02 * np.sin(2.0 * math.pi * 0.13 * t)

    # 柔和的风噪底
    noise = rng.normal(0.0, 1.0, t.size)
    noise = lowpass(noise, 420.0)
    noise /= max(np.abs(noise).max(), 1e-9)
    sig = sig / max(np.abs(sig).max(), 1e-9) * 0.85 + noise * 0.5

    # 整体音量曲线：-30 dB → -16 dB（对数推升），末尾 0.5 s 收掉，给 riser 让路
    db = np.interp(t, [0.0, 0.6, IMPACT - 0.8, IMPACT - 0.25, IMPACT],
                   [-34.0, -30.0, -18.0, -21.0, -60.0])
    gain = 10.0 ** (db / 20.0)
    x = t - IMPACT
    gain *= np.clip(1.0 - x / 0.25, 0.0, 1.0)
    return sig * gain


def make_riser() -> np.ndarray:
    start, dur = IMPACT - 1.35, 1.35
    t = t_axis(dur, start)
    u = (t - start) / dur

    # 上扫噪声（越扫越窄、越亮）
    noise = rng.normal(0.0, 1.0, t.size)
    bright = bandpass(noise, 900.0, 5200.0)
    dark = bandpass(noise, 120.0, 900.0)
    mix = dark * (1.0 - u) * 0.5 + bright * u * 0.9

    # 上扫正弦（音乐上的导火索）
    sweep = np.sin(2.0 * math.pi * np.cumsum(180.0 * (1.0 + 5.0 * u ** 2)) / SR)

    amp = 0.02 + 0.5 * u ** 2.4
    amp *= np.clip(1.0 - np.clip((t - (IMPACT - 0.06)) / 0.06, 0.0, 1.0), 0.0, 1.0)
    return (mix * 0.8 + sweep * 0.35) * amp


# ----------------------------- 爆发 -----------------------------

def make_sub_drop() -> np.ndarray:
    dur = 1.9
    t = t_axis(dur, IMPACT)
    u = t - IMPACT
    f = 92.0 * np.exp(-u * 2.4) + 31.0           # 92 Hz 快速下滑到 31 Hz
    ph = 2.0 * math.pi * np.cumsum(f) / SR
    body = np.sin(ph) + 0.25 * np.sin(2.0 * ph)
    amp = np.exp(-u * 2.1)
    click = rng.normal(0.0, 1.0, t.size) * np.exp(-u * 55.0) * 0.5
    return (body * amp + click) * 0.95


def make_crash() -> np.ndarray:
    dur = 2.4
    t = t_axis(dur, IMPACT)
    u = t - IMPACT
    noise = rng.normal(0.0, 1.0, t.size)
    band = highpass(noise, 2400.0) * np.exp(-u * 2.6)
    air = bandpass(noise, 500.0, 2400.0) * np.exp(-u * 1.5)
    return (band * 0.55 + air * 0.5)


def make_chord() -> np.ndarray:
    dur = 2.9
    t = t_axis(dur, IMPACT)
    u = t - IMPACT
    # D 大调明亮和弦：D3 A3 D4 F#4 A4
    notes = [(50, 0.55), (57, 0.42), (62, 0.36), (66, 0.24), (69, 0.18)]
    sig = np.zeros_like(t)
    for note, amp in notes:
        f = midi(note)
        for det in (-0.18, 0.0, 0.18):
            ph = 2.0 * math.pi * f * (1.0 + det / 100.0) * t
            saw = 2.0 * ((ph / (2.0 * math.pi)) % 1.0) - 1.0
            sig += saw * amp / 3.0
    sig = lowpass(sig, 2600.0)
    sig /= max(np.abs(sig).max(), 1e-9)
    # 软削波加厚度
    sig = np.tanh(sig * 1.7) * 0.9
    amp = np.exp(-u * 1.05) * (1.0 - np.exp(-u * 40.0))
    return sig * amp


def make_bell() -> np.ndarray:
    dur = 2.2
    t = t_axis(dur, IMPACT)
    u = t - IMPACT
    sig = np.zeros_like(t)
    for f0, amp, decay in ((midi(86), 0.5, 2.2), (midi(93), 0.28, 3.0), (midi(98), 0.16, 4.0)):
        sig += np.sin(2.0 * math.pi * f0 * t) * amp * np.exp(-u * decay)
    return sig * 0.55


def make_tail() -> np.ndarray:
    """爆发后的余响 pad，接到标题画面不突兀。"""
    start, dur = IMPACT + 1.6, DUR - IMPACT - 1.6
    t = t_axis(dur, start)
    u = t - start
    sig = np.zeros_like(t)
    for note, amp in ((38, 0.5), (45, 0.36), (57, 0.2)):
        f = midi(note)
        ph = 2.0 * math.pi * f * t
        sig += (np.sin(ph) * 0.7 + np.sin(2.0 * ph) * 0.15) * amp
    fade = np.clip(1.0 - u / dur, 0.0, 1.0) ** 1.6
    return sig * fade * 0.25


def main() -> None:
    total = int(DUR * SR)
    buf = np.zeros(total, dtype=np.float64)

    add(buf, make_pad(), 0.0, 0.85)
    add(buf, make_riser(), IMPACT - 1.35, 1.0)
    add(buf, make_sub_drop(), IMPACT, 0.95)
    add(buf, make_crash(), IMPACT, 0.5)
    add(buf, make_chord(), IMPACT + 0.005, 0.42)
    add(buf, make_bell(), IMPACT + 0.01, 0.5)
    add(buf, make_tail(), IMPACT + 1.6, 1.0)

    # 简易立体声：用 6 ms 的左右微差 + 后段轻微 reverb 感
    delay = int(0.011 * SR)
    left = buf.copy()
    right = np.concatenate([np.zeros(delay), buf[:-delay]])
    right += buf * 0.35
    left += np.concatenate([buf[delay:], np.zeros(delay)]) * 0.2

    st = np.stack([left, right], axis=1)
    # 归一化 + 软限幅，爆发瞬间不硬削
    peak = np.abs(st).max()
    st = st / max(peak, 1e-9) * 0.86
    st = np.tanh(st * 1.15) * 0.92
    # 首尾各 10 ms 淡入淡出，避免爆音
    nf = int(0.01 * SR)
    st[:nf] *= np.linspace(0.0, 1.0, nf)[:, None]
    st[-nf:] *= np.linspace(1.0, 0.0, nf)[:, None]

    pcm = (np.clip(st, -1.0, 1.0) * 32767.0).astype("<i2")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())

    peak_db = 20.0 * math.log10(max(np.abs(st).max(), 1e-9))
    print(f"wrote {OUT}  {DUR:.1f}s  {SR} Hz  stereo  peak {peak_db:.2f} dBFS  impact @ {IMPACT:.2f}s")


if __name__ == "__main__":
    main()
