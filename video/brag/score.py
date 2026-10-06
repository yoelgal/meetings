#!/usr/bin/env python3
"""The launch film's score, synthesized from nothing, so there is no track whose licence this repo
has to vouch for. Standard library only. Renders to a file; it never plays anything.

    python3 video/brag/score.py video/film/public/launch/score.wav

100 BPM (a beat is 0.6 s, the film's cut grid), A minor, i-VI-III-VII. The effects are part of the
piece rather than laid on it: the ticks are pitched to the key, the boom is the tonic, the riser lands
on the downbeat the reveal cuts on, and every one of them sits well under the music.
"""
import math
import random
import struct
import sys
import wave

SR = 48_000
DUR = 34.0
BEAT = 0.6
N = int(SR * DUR)
L = [0.0] * N
R = [0.0] * N
rng = random.Random(7)


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def add(start, samples, gain=1.0, pan=0.0):
    i0 = int(start * SR)
    gl, gr = gain * (1 - max(pan, 0)), gain * (1 + min(pan, 0))
    for k, v in enumerate(samples):
        i = i0 + k
        if 0 <= i < N:
            L[i] += v * gl
            R[i] += v * gr


def pluck(freq, length=0.5, bright=0.35):
    n = int(SR * length)
    out = []
    for k in range(n):
        t = k / SR
        env = math.exp(-t * 7.5) * min(1.0, t * 400)
        out.append(env * (math.sin(2 * math.pi * freq * t)
                          + bright * math.sin(4 * math.pi * freq * t) * math.exp(-t * 14)))
    return out


def pad(freqs, length, attack=0.6, release=0.8):
    n = int(SR * length)
    out = [0.0] * n
    for f in freqs:
        for det in (-0.12, 0.12):
            ff = f * 2 ** (det / 12)
            ph = rng.random() * 6.28
            for k in range(n):
                t = k / SR
                out[k] += (math.sin(2 * math.pi * ff * t + ph) + 0.3 * math.sin(4 * math.pi * ff * t + ph)) * 0.12
    for k in range(n):
        t = k / SR
        env = min(1.0, t / attack) * min(1.0, (length - t) / release)
        out[k] *= max(env, 0.0)
    return out


def bass(freq, length):
    n = int(SR * length)
    return [math.tanh(1.6 * math.sin(2 * math.pi * freq * k / SR)) * math.exp(-k / SR * 3.2)
            * min(1.0, k / SR * 200) for k in range(n)]


def kick():
    n = int(SR * 0.35)
    out, ph = [], 0.0
    for k in range(n):
        t = k / SR
        ph += 2 * math.pi * (48 + 90 * math.exp(-t * 30)) / SR
        out.append(math.sin(ph) * math.exp(-t * 9))
    return out


def tick(freq):
    n = int(SR * 0.05)
    return [math.sin(2 * math.pi * freq * k / SR) * math.exp(-k / SR * 90) for k in range(n)]


def lowpass(samples, cutoff):
    a = 1 - math.exp(-2 * math.pi * cutoff / SR)
    y, out = 0.0, []
    for v in samples:
        y += a * (v - y)
        out.append(y)
    return out


def noise_sweep(length, rising=True):
    n = int(SR * length)
    out, y = [], 0.0
    for k in range(n):
        p = k / n if rising else 1 - k / n
        a = 0.02 + 0.5 * p * p
        y += a * (rng.uniform(-1, 1) - y)
        out.append(y * (p ** 1.5 if rising else (1 - k / n) ** 2))
    return out


# Chords (MIDI): Am, F, C, G
CHORDS = [(57, 60, 64), (53, 57, 60), (48, 52, 55), (55, 59, 62)]
ROOTS = [45, 41, 36, 43]
BAR = 4 * BEAT
# The end card's downbeat: 6.6 s + 39 beats. The groove stops *before* it, so the card's hit
# is the only kick there — not a second one a fifth of a second after the groove's last.
END = 30.0  # 6.6 + 39 * BEAT, written out so float rounding cannot put a beat on either side

# --- Hook (0 - 3.0): a held tonic, typing ticks, then the question lands on a low boom.
add(0.0, pad([hz(57), hz(64)], 3.2, attack=0.4), 0.30)
for i in range(18):
    add(0.15 + i * 0.047, tick(hz(81 + (i % 3) * 2)), 0.07, pan=rng.uniform(-0.3, 0.3))
add(1.8, kick(), 0.55)
add(1.8, bass(hz(33), 1.2), 0.30)

# --- Problem (3.0 - 6.6): the same idea, muffled — one mixed track.
for b in range(6):
    add(3.0 + b * BEAT, lowpass(pluck(hz(57), 0.55), 700), 0.30)
add(3.0, lowpass(pad([hz(57), hz(60), hz(64)], 3.6), 900), 0.35)
add(5.4, noise_sweep(1.2), 0.18)

# --- Reveal onwards (6.6 - 30.0): the groove, one chord per bar.
start = 6.6
bar = 0
while start + bar * BAR < END - 0.01:
    t0 = start + bar * BAR
    ci = bar % 4
    chord = CHORDS[ci]
    add(t0, pad([hz(m) for m in chord], BAR + 0.4), 0.26, pan=-0.15)
    for b in range(4):
        tb = t0 + b * BEAT
        if tb >= END - 0.01:
            break
        add(tb, kick(), 0.32)
        add(tb, bass(hz(ROOTS[ci]), BEAT * 0.95), 0.22)
        for e in range(2):
            note = chord[(b * 2 + e) % 3] + 12
            add(tb + e * BEAT / 2, pluck(hz(note), 0.45), 0.16, pan=0.25 if e else -0.25)
    bar += 1
add(6.6, kick(), 0.6)  # the downbeat the reveal cuts on

# Scene cuts get a soft breath, under the music.
for cut in (10.2, 16.2, 20.4, 24.6):
    add(cut - 0.35, noise_sweep(0.45), 0.07)

# Terminal typing (24.6 - 27.3), pitched to the key and quiet.
for i in range(40):
    add(24.65 + i * 0.065, tick(hz((69, 72, 76)[i % 3] + 12)), 0.035, pan=rng.uniform(-0.4, 0.4))

# --- End card (30.0 - 34.0): resolve to the tonic and let it ring out.
add(END, kick(), 0.5)
add(END, bass(hz(33), 2.5), 0.28)
add(END, pad([hz(57), hz(60), hz(64), hz(69)], 4.0, attack=0.1, release=2.6), 0.34)
for i, m in enumerate((69, 72, 76, 81)):
    add(END + i * 0.15, pluck(hz(m), 1.4, 0.2), 0.12)

# Master: fade the tail, gentle saturation, peak at about -1 dBFS.
for i in range(N):
    t = i / SR
    fade = min(1.0, (DUR - t) / 1.2)
    L[i] *= fade
    R[i] *= fade
peak = max(max(abs(v) for v in L), max(abs(v) for v in R)) or 1.0
scale = 0.89 / math.tanh(1.0)
out = sys.argv[1]
with wave.open(out, 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    frames = bytearray()
    for i in range(N):
        a = scale * math.tanh(L[i] / peak)
        b = scale * math.tanh(R[i] / peak)
        frames += struct.pack('<hh', int(a * 32767), int(b * 32767))
    w.writeframes(bytes(frames))
print(out)
