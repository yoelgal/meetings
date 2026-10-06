#!/usr/bin/env python3
"""The launch film's soundtrack, built only from real recordings — and checked, not listened to.

    video/brag/fetch-sounds.sh       # the CC0 recordings, once
    video/brag/finish.sh             # render, score, mux, verify — the way to build the film

or by hand, with a silent render of the picture to place fades by:

    python3 video/brag/soundtrack.py --picture video/brag/work-render.mp4
    python3 video/brag/soundtrack.py --picture video/brag/work-render.mp4 --verify video/brag/brag.mp4

Every cut and every click in the film gets its own sound: a marble, a key, a switch, a glass, a
keystroke, a pen. The melody is a marimba, a grand piano and a contrabass played by people, re-pitched
by resampling (which is all a sampler ever does). Nothing is synthesised.

**Where the sounds land.** The event times come from two places, never from guesses:
- `video/film/src/launch/timing.json`, which Launch.tsx draws from, plus the same frame formulas
  Launch.tsx uses for the type-on text, so each keystroke sound lands on the frame its character does;
- the captured clips themselves. ScreenCaptureKit footage of an idle window repeats a byte-identical
  ProRes frame, so a change in frame size *is* a change in the picture: that is where a transcript
  line arrived, or the write-up landed, inside the app.
Each recording is aligned by its own detected attack, not by its file start, so the first audible
sample of the hit is the frame the thing appears on.

**Checked, because nobody here can listen.** `--verify` reads back the rendered film and prints, per
event, how far the audio's attack and the picture's change sit from where they were meant to be,
plus integrated loudness and true peak. The build itself also measures its own output and refuses
to finish outside the loudness target.

Standard library only (plus ffmpeg/ffprobe for decoding and loudness measurement).
"""
import array
import json
import math
import random
import subprocess
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOUNDS = ROOT / "video/film/public/launch/sounds"
CLIPS = ROOT / "video/film/public/launch"
OUT = CLIPS / "soundtrack.wav"
TIMING = json.loads((ROOT / "video/film/src/launch/timing.json").read_text())
SESSION = json.loads((ROOT / "video/film/src/launch/session.json").read_text())

SR = 48_000
FPS = 60
TARGET_LUFS = -16.0      # integrated; loud enough to post, quiet enough to leave the hits their attack
CEILING_DBTP = -1.0      # true peak
S = TIMING["scenes"]
N = int(S["total"] * SR)
L = array.array("f", bytes(4 * N))
R = array.array("f", bytes(4 * N))
rng = random.Random(11)
PLACED = []              # (time, label, kind) for the report
ALONE = []               # the sound each of those events placed, for reading back in isolation


def frame_time(f):
    return f / FPS


def sec_frames(s):
    return round(s * FPS)      # Remotion's `sec()`: Math.round(seconds * FPS)


def db(x):
    return 10 ** (x / 20)


# MARK: - Audio in

_cache = {}


def load(name):
    if name not in _cache:
        with wave.open(str(SOUNDS / f"{name}.wav"), "rb") as w:
            assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2, name
            raw = array.array("h", w.readframes(w.getnframes()))
        _cache[name] = array.array("f", (v / 32768 for v in raw))
    return _cache[name]


def peak(x):
    return max((abs(v) for v in x), default=0.0)


def attack(x, frac=0.2):
    """Index of the start of the first transient: first sample over `frac` of the peak, walked back
    to where the attack begins (under 3% of peak), at most 8 ms. This is the sample that is put on
    the event's frame."""
    p = peak(x) or 1.0
    i = next((k for k, v in enumerate(x) if abs(v) >= frac * p), 0)
    j = i
    while j > 0 and i - j < int(0.008 * SR) and abs(x[j - 1]) > 0.03 * p:
        j -= 1
    return j


def slices(x, gap=0.06, length=0.35, floor=0.12):
    """Individual hits out of a longer recording: an onset is a 2 ms window over `floor` of the
    peak after at least `gap` seconds under a tenth of it. Each slice runs to the next onset or
    `length`, with a short fade so it never clicks off."""
    hop = int(0.002 * SR)
    env = [max(abs(v) for v in x[i:i + hop]) for i in range(0, len(x) - hop, hop)]
    p = max(env) or 1.0
    quiet_for = int(gap / 0.002)
    out, quiet = [], quiet_for
    for k, e in enumerate(env):
        if e >= floor * p and quiet >= quiet_for:
            out.append(k * hop)
            quiet = 0
        elif e < 0.1 * p:
            quiet += 1
        else:
            quiet = 0
    cuts = []
    for n, start in enumerate(out):
        start = max(0, start - int(0.004 * SR))
        end = min(len(x), start + int(length * SR), out[n + 1] - int(0.002 * SR) if n + 1 < len(out) else len(x))
        s = x[start:end]
        fade(s, 0.02)
        if len(s) > int(0.03 * SR):
            cuts.append(s)
    return cuts


def fade(s, seconds, start_at=None):
    n = min(len(s), int(seconds * SR))
    begin = len(s) - n if start_at is None else start_at
    for k in range(n):
        if begin + k < len(s):
            s[begin + k] *= 1 - k / n
    if start_at is not None:
        for k in range(begin + n, len(s)):
            s[k] = 0.0


def repitch(x, semitones):
    """Resample: the recording played faster or slower, which is how every sampler re-pitches."""
    if semitones == 0:
        return array.array("f", x)
    r = 2 ** (semitones / 12)
    n = int((len(x) - 1) / r)
    out = array.array("f", bytes(4 * n))
    for i in range(n):
        p = i * r
        k = int(p)
        f = p - k
        out[i] = x[k] * (1 - f) + x[k + 1] * f
    return out


def normalised(x, to=1.0):
    p = peak(x) or 1.0
    return array.array("f", (v * to / p for v in x))


# MARK: - Placing

def place(x, t, gain_db, pan=0.0, label="", kind="hit", align=True):
    """Put `x` so its attack lands on `t` seconds. Constant-power pan, -1 left … 1 right."""
    if align:
        # Nothing may sound before the thing it scores: anything more than 10 ms ahead of the
        # attack is room tone or a pre-rattle, and is dropped rather than played early.
        x = x[max(0, attack(x) - int(0.010 * SR)):]
    start = int(round(t * SR)) - (attack(x) if align else 0)
    g = db(gain_db)
    a = math.cos((pan + 1) * math.pi / 4) * g
    b = math.sin((pan + 1) * math.pi / 4) * g
    for k, v in enumerate(x):
        i = start + k
        if 0 <= i < N:
            L[i] += v * a
            R[i] += v * b
    if label:
        PLACED.append((t, label, kind))
        ALONE.append(x)


# MARK: - The instruments

MARIMBA = {"G2": 43, "B2": 47, "F3": 53, "C4": 60, "G4": 67, "B4": 71, "F5": 77, "C6": 84}
PIANO = {"A2": 45, "C3": 48, "B3": 59, "A4": 69, "C5": 72}
PIZZ = {"C1": 24, "D1": 26, "E1": 28, "F#1": 30, "G#1": 32, "A1": 33, "C#2": 37, "E2": 40}
_notes = {}


def note(family, table, midi, seconds=None):
    """The nearest recorded note, re-pitched to `midi`, optionally cut to `seconds` with a fade."""
    key = (family, midi, seconds)
    if key not in _notes:
        name, base = min(table.items(), key=lambda kv: abs(kv[1] - midi))
        x = repitch(normalised(load(f"{family}_{name}")), midi - base)
        x = x[attack(x):]
        if seconds is not None and len(x) > seconds * SR:
            x = x[: int(seconds * SR)]
            fade(x, min(0.25, seconds / 3))
        _notes[key] = x
    return _notes[key]


def marimba(midi, t, gain_db, pan=0.0):
    place(note("marimba", MARIMBA, midi, 1.6), t, gain_db, pan, kind="note")


def piano(midis, t, gain_db, hold, pan=0.0):
    for m in midis:
        place(note("piano", PIANO, m, hold), t, gain_db - 3 * math.log2(len(midis)), pan, kind="note")


def pizz(midi, t, gain_db, seconds=1.2):
    place(note("pizz", PIZZ, midi, round(seconds, 3)), t, gain_db, -0.05, kind="note")


# MARK: - The hits

def pool(name, **kw):
    return [normalised(s) for s in slices(load(name), **kw)]


KEYS = pool("keyboard_mech", gap=0.04, length=0.12, floor=0.25)[:40]
MARBLES = pool("marble_table", gap=0.08, length=0.4, floor=0.3)[:24]
MARBLE_TILE = pool("marble_tile", gap=0.08, length=0.4, floor=0.3)[:12]
SWITCH = pool("switch_light", gap=0.1, length=0.25, floor=0.3)[:8]
PEN = pool("pen_click", gap=0.06, length=0.2, floor=0.3)[:12]
GLASS_TAP = pool("glass_bottles", gap=0.05, length=0.6, floor=0.3)
FLICK = normalised(load("switch_flick"))
DESK_MARBLE = normalised(load("marble_desk"))
GLASS_WINDOW = normalised(load("glass_window"))
GLASS_PLACE = normalised(load("glass_place"))
# The pickup recording rattles for a second before the keys leave the table; aligned by that main
# attack, the rattle sounded a second *before* the picture. Its crispest single transient instead.
_pickup = load("keys_pickup")
_main = attack(_pickup, frac=0.5)
KEYS_PICKUP = normalised(_pickup[max(0, _main - int(0.015 * SR)): _main + int(0.6 * SR)])
fade(KEYS_PICKUP, 0.15)
KEYS_JINGLE = normalised(load("keys_jingle")[: int(1.2 * SR)])
fade(KEYS_JINGLE, 0.4)

for name, got in [("keyboard", KEYS), ("marble", MARBLES), ("tile", MARBLE_TILE),
                  ("switch", SWITCH), ("pen", PEN), ("glass", GLASS_TAP)]:
    if not got:
        sys.exit(f"soundtrack: no usable hits sliced out of the {name} recording")


def cycle(seq, n):
    return seq[n % len(seq)]


GRID = (24, 18)  # cells across, down — each 8x6 px of a 192x108 picture, 80x60 of the film


def picture_cells(video):
    """Per frame, per cell of a 24x18 grid: the summed absolute change from the previous frame. A
    grid rather than a whole-frame number, so a word arriving in one corner still registers while
    a push-in moves everything else a little."""
    w, h = 192, 108
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(video), "-vf",
                          f"scale={w}:{h},format=gray", "-f", "rawvideo", "-"],
                         capture_output=True, check=True).stdout
    size = w * h
    frames = [raw[i:i + size] for i in range(0, len(raw) - size + 1, size)]
    cw, ch = w // GRID[0], h // GRID[1]
    cells = [[0] * (GRID[0] * GRID[1])]
    for prev, cur in zip(frames, frames[1:]):
        row = [0] * (GRID[0] * GRID[1])
        for y in range(h):
            base, cy = y * w, (y // ch) * GRID[0]
            for x in range(w):
                d = cur[base + x] - prev[base + x]
                if d:
                    row[cy + x // cw] += d if d > 0 else -d
        cells.append(row)
    return cells


# A silent render of the film, when given (`--picture work-render.mp4`): fades are placed on the
# frame they become visible, measured, rather than on the frame their opacity curve starts at zero.
PICTURE = picture_cells(Path(sys.argv[sys.argv.index("--picture") + 1])) if "--picture" in sys.argv else None


def visible(t, search=15):
    """The first frame at or after `t` on which some region of the picture that was still for
    three frames changes by a visible amount. A smoothstep fade spends its first frames under one
    grey level, so its sound belongs where the eye first catches it, not where the curve starts."""
    if PICTURE is None:
        return t
    f0 = round(t * FPS)
    for f in range(f0, min(len(PICTURE), f0 + search)):
        if changes(PICTURE, f):
            return frame_time(f)
    return t


def changes(cells, f):
    """A region of the picture starts changing on frame `f`: a cell still for three frames moves by
    a visible amount, or a cell already moving (a waveform, a settling mark, a line fading out
    under the one fading in) suddenly does at least twice what it was doing."""
    for c in range(len(cells[f])):
        before = max(cells[k][c] for k in range(max(1, f - 3), f))
        now = cells[f][c]
        if (now >= 25 and before < 10) or (now >= 20 and now > 2 * before and before >= 1):
            return True
    return False


# MARK: - Events: the picture's own clock

def clip_changes(name, min_delta=1500):
    """Times inside a captured clip where the window changed: a change in ProRes frame size."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=pts_time,size",
         "-of", "csv=p=0", str(CLIPS / name)], capture_output=True, text=True, check=True).stdout
    rows = [tuple(map(float, line.split(",")[:2])) for line in out.split()]
    return [t for (t, s), (_, prev) in zip(rows[1:], rows) if abs(s - prev) > min_delta]


def type_frames(start, end, length):
    """The frames on which a type-on adds characters: exactly Launch.tsx's
    `frame < start ? nothing : floor(interpolate(frame, [start, end], [0, length]))` — clamped, in
    floats, so a fractional start or end lands on the same frame it does on screen."""
    out, last = [], 0
    for f in range(math.floor(start), math.ceil(end) + 2):
        if f < start:
            continue
        typed = length if end <= start else math.floor(min(1.0, max(0.0, (f - start) / (end - start))) * length)
        if typed > last:
            out.append(f)
            last = typed
    return out


CUTS = [S["problem"], S["reveal"], S["live"], S["anchored"], S["share"], S["cli"], S["end"]]

# Hook: one keystroke per character as it appears, then the question lands.
H = TIMING["hook"]
for n, f in enumerate(type_frames(sec_frames(H["typeStart"]), sec_frames(H["typeEnd"]), len(H["line"]))):
    place(cycle(KEYS, n), frame_time(f), -21, rng.uniform(-0.25, 0.25), f"hook key {n + 1}", "key")
place(DESK_MARBLE, H["question"], -12, 0.0, "hook: Who said that?", "hit")
piano([45], H["question"], -14, 2.6)

# Cuts: each its own object.
cut_sounds = [cycle(MARBLE_TILE, 0), cycle(MARBLES, 2), cycle(MARBLE_TILE, 1), cycle(MARBLES, 5), cycle(MARBLE_TILE, 2), cycle(MARBLES, 8), GLASS_PLACE]
for n, t in enumerate(CUTS):
    place(cut_sounds[n], visible(t), -16 if n < 6 else -17, (-0.2, 0.2)[n % 2], f"cut {t:.1f}s", "cut")

# Problem: each line switches on.
P = TIMING["problem"]
place(cycle(SWITCH, 0), visible(S["problem"] + P["lineA"]), -15, -0.15, "problem line A", "fade")
place(FLICK, visible(S["problem"] + P["lineB"]), -15, 0.15, "problem line B", "fade")

# Reveal: the split, the two labels, the mark.
Rv = TIMING["reveal"]
place(KEYS_PICKUP, visible(S["reveal"] + Rv["split"]), -16, 0.0, "reveal: tracks split", "fade")
place(cycle(GLASS_TAP, 0), visible(S["reveal"] + Rv["labels"]), -15, -0.3, "reveal: You / Others", "fade")
place(GLASS_WINDOW, visible(S["reveal"] + Rv["mark"]), -13, 0.1, "reveal: Meetings records them", "fade")

# Live: each transcript line as the app draws it — glass for the other side, a pen for you.
# The seeded dialogue alternates system, mic, system, …, starting with the other side.
trim = TIMING["live"]["trim"]
live_len = S["anchored"] - S["live"]
# Each line's speaker comes from the shoot's own record of what it seeded and when (seconds after
# capture began), matched to the first change in the footage at or after that moment. Counting
# changes instead put every Others sound on You once, when a capture started late and line 1 was
# already in its first frame — and timing checks cannot see a swapped speaker.
schedule = [(float(a), ch) for a, ch in (line.split() for line in
            (CLIPS / "live-schedule.txt").read_text().splitlines() if line.strip())]
live_changes = clip_changes("live.mov")
lines, used = [], set()
for seeded, ch in schedule:
    # The schedule is written when `seed say` exits; the app has usually redrawn ~0.1 s before
    # that. The nearest unused change within a window narrower than the 1.25 s between lines.
    near = [t for t in live_changes if t not in used and -0.6 <= t - seeded <= 1.0]
    match = min(near, key=lambda t: abs(t - seeded), default=None)
    if match is None:
        sys.exit(f"soundtrack: the {ch} line seeded at {seeded:.2f}s never shows in live.mov — re-shoot")
    used.add(match)
    lines.append((match, ch))
for n, (t, ch) in enumerate(lines):
    if not trim <= t < trim + live_len:
        continue
    other = ch == "system"
    place(cycle(GLASS_TAP, n) if other else cycle(PEN, n), S["live"] + t - trim, -17,
          -0.35 if other else 0.35, f"live line {n + 1} ({'Others' if other else 'You'})", "click")

# Share: the panel leaves the shared screen.
place(cycle(SWITCH, 1), visible(S["share"] + TIMING["share"]["panelGone"]), -15, 0.3, "share: panel hidden", "fade")

# CLI: keystrokes on the frames characters appear (no two closer than two frames — at the
# terminal's speed a key per frame is a buzz, not typing), a pen click as each answer appears,
# the cut back to the app, and the write-up landing in it.
C = TIMING["cli"]
lead = sec_frames(C["lead"])
per = (sec_frames(C["typing"]) - lead) / len(SESSION)
for i, step in enumerate(SESSION):
    start = lead + i * per
    type_end = start + min(len(step["command"]) * C["framesPerChar"], per * C["typingShare"])
    last = -10
    for n, f in enumerate(type_frames(start, type_end, len(step["command"]))):
        if f - last >= 2:
            place(cycle(KEYS, 7 * i + n), S["cli"] + frame_time(f), -24, rng.uniform(-0.3, 0.3),
                  f"cli step {i + 1} key", "key")
            last = f
    out_f = math.ceil(type_end + sec_frames(C["outputAfter"]))
    place(cycle(PEN, i + 3), visible(S["cli"] + frame_time(out_f)), -18, 0.2, f"cli step {i + 1} output", "fade")
place(cycle(MARBLES, 11), S["cli"] + C["terminal"], -14, -0.2, "cli: back to the app", "cut")
on_screen = S["end"] - S["cli"] - C["terminal"]
landed = [t for t in clip_changes("writeup.mov") if C["writeupTrim"] <= t < C["writeupTrim"] + on_screen]
if not landed:
    sys.exit("soundtrack: the write-up never lands while writeup.mov is on screen — re-shoot it")
landing = landed[0]
land_t = S["cli"] + C["terminal"] + landing - C["writeupTrim"]
place(KEYS_JINGLE, land_t, -15, 0.15, "cli: write-up lands", "hit")
place(cycle(GLASS_TAP, 1), land_t, -16, -0.2, "", "hit")

# End card: the mark, the line, the install command, the small print.
E = TIMING["end"]
place(GLASS_WINDOW, visible(S["end"] + E["mark"]), -16, 0.0, "end: Meetings", "fade")
place(cycle(GLASS_TAP, 2), visible(S["end"] + E["tag"]), -16, -0.2, "end: tagline", "fade")
place(cycle(KEYS, 3), visible(S["end"] + E["install"]), -15, 0.2, "end: install line", "fade")
place(cycle(SWITCH, 2), visible(S["end"] + E["meta"]), -17, 0.0, "end: macOS 26 …", "fade")


# The hits alone, kept for verification before the music is added on top of them.
HITS = (array.array("f", L), array.array("f", R))

# MARK: - Music: marimba, piano, pizzicato bass, A minor, 100 BPM

BEAT = 0.6
BAR = 4 * BEAT
# i–VI–III–VII: Am, F, C, G. Bass roots, then the triads the marimba walks and the piano holds.
CHORDS = [(33, (57, 60, 64)), (29, (53, 57, 60)), (36, (48, 52, 55)), (31, (55, 59, 62))]

# Problem: the bass alone, one note a beat, the room before the music arrives.
t = S["problem"]
while t < S["reveal"] - 0.01:
    pizz(33, t, -15)
    t += BEAT

# From the reveal to the end card: the groove. It stops before the end card's downbeat so the
# card's own hit is the only thing there.
bar = 0
while S["reveal"] + bar * BAR < S["end"] - 0.01:
    t0 = S["reveal"] + bar * BAR
    root, triad = CHORDS[bar % 4]
    # Held to the next bar, but never past the end card's downbeat, which is the card's alone.
    piano([m - 12 for m in triad], t0, -16, min(BAR + 0.3, S["end"] - t0), pan=-0.15)
    for b in range(4):
        tb = t0 + b * BEAT
        if tb >= S["end"] - 0.01:
            break
        pizz(root if b % 2 == 0 else root + 7, tb, -11, min(1.2, S["end"] - tb))
        for e in range(2):
            m = (triad + tuple(x + 12 for x in triad))[(b * 2 + e) % 6] + 12
            marimba(m, tb + e * BEAT / 2, -18 if e else -16, 0.25 if e else -0.25)
    bar += 1

# End card: resolve on A minor and let the real instruments ring out.
pizz(33, S["end"], -11)
piano([45, 48, 52, 57], S["end"], -12, S["total"] - S["end"])
for n, m in enumerate((69, 72, 76, 81)):
    marimba(m, S["end"] + E["mark"] + n * 0.15, -16, (-0.3, -0.1, 0.1, 0.3)[n])


# MARK: - Master

CEILING = db(-1.8)   # sample-peak ceiling; the margin below -1 dBTP is for inter-sample peaks


def limit(gain):
    """A look-ahead peak limiter: per sample, the gain that keeps the louder channel under the
    ceiling, held as a minimum over 1.5 ms ahead (so the gain is already down when the attack
    arrives) and released over 80 ms. It only ever touches the odd stacked transient; everywhere
    else the gain is exactly `gain`."""
    ahead = int(0.0015 * SR)
    release = math.exp(-1 / (0.08 * SR))
    need = array.array("f", (min(1.0, CEILING / (max(abs(L[i]), abs(R[i])) * gain + 1e-12)) for i in range(N)))
    held = array.array("f", need)
    window = []  # monotonic deque of (index, value) for a running minimum over [i, i + ahead]
    for i in range(N - 1, -1, -1):
        while window and window[-1][1] >= need[i]:
            window.pop()
        window.append((i, need[i]))
        while window[0][0] > i + ahead:
            window.pop(0)
        held[i] = window[0][1]
    g, out = 1.0, array.array("f", bytes(4 * N))
    for i in range(N):
        g = held[i] if held[i] < g else held[i] + (g - held[i]) * release
        out[i] = g * gain
    return out


def write(path, gain):
    gains = limit(gain)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        out = array.array("h", bytes(4 * N))
        tail = int(1.2 * SR)
        for i in range(N):
            f = min(1.0, (N - i) / tail) * gains[i]
            out[2 * i] = int(max(-1.0, min(1.0, L[i] * f)) * 32767)
            out[2 * i + 1] = int(max(-1.0, min(1.0, R[i] * f)) * 32767)
        w.writeframes(out.tobytes())


def loudness(path):
    err = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-af", "ebur128=peak=true",
         "-f", "null", "-"], capture_output=True, text=True).stderr
    summary = err[err.rfind("Summary:"):]
    i = float(summary.split("I:")[1].split("LUFS")[0])
    tp = float(summary.split("Peak:")[1].split("dBFS")[0])
    return i, tp


def master():
    gain = 1.0
    for _ in range(4):
        write(OUT, gain)
        i, tp = loudness(OUT)
        if abs(i - TARGET_LUFS) <= 0.5 and tp <= CEILING_DBTP:
            return i, tp
        # The limiter holds the peaks, so the gain only has to find the loudness.
        gain *= db(TARGET_LUFS - i)
    return loudness(OUT)


# MARK: - Verification

def stem_attack(mono, t, before=0.02, after=0.016):
    """The attack nearest `t` in a hits-only stem: first sample over 20% of the local peak in a
    window that looks further back than the pass mark (half a frame), so a sound that lands early
    reads as early instead of at the window's edge."""
    a, b = max(0, int((t - before) * SR)), min(len(mono), int((t + after) * SR))
    seg = mono[a:b]
    p = peak(seg)
    if p < 1e-4:
        return None
    k = next(i for i, v in enumerate(seg) if abs(v) >= 0.2 * p)
    while k > 0 and abs(seg[k - 1]) > 0.03 * p:
        k -= 1
    return (a + k) / SR - t


def decoded(video):
    tmp = Path("/tmp/meetings-soundtrack-verify.wav")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(video), "-ac", "1", "-ar", str(SR),
                    "-c:a", "pcm_s16le", str(tmp)], check=True)
    with wave.open(str(tmp), "rb") as w:
        return array.array("f", (v / 32768 for v in array.array("h", w.readframes(w.getnframes()))))


def mux_offset(film, reference):
    """How far the film's audio sits from the soundtrack it was rendered with: the lag that best
    lines the two up, searched to ±50 ms around three loud moments. An AAC encoder adds priming
    samples; this proves the container's edit list takes them back out."""
    lags = []
    for t in (1.8, 10.2, 30.05):
        c = int(t * SR)
        ref = reference[c - 2400:c + 2400]
        best = max(range(-2400, 2401, 4),
                   key=lambda lag: sum(ref[k] * film[c - 2400 + k + lag] for k in range(0, len(ref), 4)))
        fine = max(range(best - 4, best + 5),
                   key=lambda lag: sum(ref[k] * film[c - 2400 + k + lag] for k in range(0, len(ref), 2)))
        lags.append(fine / SR)
    return lags


def picture_event(cells, f, kind):
    """Did the picture change on frame `f` the way this kind of event changes it?
    - key: a glyph appeared on exactly this frame (some cell changed between f-1 and f).
    - cut: the new scene is arriving (change across the next eight frames).
    - anything else: a region still for three frames changes on this frame or the next."""
    if f >= len(cells):
        return False
    if kind == "key":
        # The terminal is dead still between keystrokes (0), so any change is the glyph; a narrow
        # one like `y` moves an 8x6 cell by as little as 14.
        return max(cells[f]) >= 8
    if kind == "cut":
        return sum(sum(cells[k]) for k in range(f, min(len(cells), f + 8))) > 2000
    return any(changes(cells, g) for g in (f, f + 1) if g < len(cells))


def verify(video):
    film = decoded(video)
    with wave.open(str(OUT), "rb") as w:
        st = array.array("h", w.readframes(w.getnframes()))
    reference = array.array("f", ((st[2 * i] + st[2 * i + 1]) / 65536 for i in range(len(st) // 2)))
    hits = array.array("f", ((a + b) / 2 for a, b in zip(*HITS)))
    lags = mux_offset(film, reference)
    cells = picture_cells(video)

    # Each event's own sound, placed alone in silence exactly as the mix placed it, and read back:
    # the placement itself. The stem read-back below sees neighbours too (a keystroke's tail is
    # still ringing when the next one, 33 ms later, lands), so it bounds the context, not the aim.
    alone = 0.0
    for x in ALONE:
        buf = array.array("f", bytes(4 * SR))
        start = SR // 2 - attack(x)
        for k, v in enumerate(x[: SR // 2]):
            buf[start + k] += v
        alone = max(alone, abs(stem_attack(buf, 0.5) or 0.0))
    rows, worst = [], 0.0
    seen = 0
    for t, label, kind in sorted(PLACED):
        e = stem_attack(hits, t)
        moved = picture_event(cells, round(t * FPS), kind)
        seen += moved
        rows.append((t, label, e, moved))
        if e is not None:
            worst = max(worst, abs(e))
    i, tp = loudness(video)
    print(f"{'time':>7}  {'attack Δ':>9}  {'picture':>8}  event")
    for t, label, e, moved in rows:
        print(f"{t:7.3f}  {('%+.2f ms' % (e * 1000)) if e is not None else '      ?':>9}  "
              f"{('changes' if moved else 'STEADY'):>8}  {label}")
    print(f"\n{len(rows)} events")
    print(f"  each sound's attack vs its frame, read back alone: worst {alone * 1000:.2f} ms "
          f"(one frame is {1000 / FPS:.1f} ms)")
    print(f"  …and read back in the full hits stem, neighbours ringing: worst {worst * 1000:.2f} ms")
    print(f"  film audio vs soundtrack (codec delay): {', '.join('%+.2f ms' % (x * 1000) for x in lags)}")
    print(f"  picture starts changing on the event's frame (within 3 frames): {seen}/{len(rows)}")
    print(f"  loudness of the finished film: {i:.1f} LUFS integrated, true peak {tp:.1f} dBTP")
    print("  short-term loudness by scene (LUFS, 3 s window): the hook quiet, the groove level, the end ringing out")
    log = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-v", "verbose", "-i", str(video), "-af",
                          "ebur128", "-f", "null", "-"], capture_output=True, text=True).stderr
    st = []
    for line in log.splitlines():
        if " t: " in line and " S:" in line:
            st.append((float(line.split(" t:")[1].split()[0]), float(line.split(" S:")[1].split()[0])))
    names = ["hook", "problem", "reveal", "live", "anchored", "share", "cli", "end"]
    bounds = [S[n] for n in names] + [S["total"]]
    for n, a, b in zip(names, bounds, bounds[1:]):
        v = sorted(x for t, x in st if a + 0.5 <= t < b and x > -70)
        if v:
            print(f"    {n:9s} {a:5.1f}–{b:5.1f}s   median {v[len(v) // 2]:6.1f}   max {v[-1]:6.1f}")
    return alone, lags, seen, i, tp


if __name__ == "__main__":
    if "--verify" in sys.argv:
        # Gated on each sound read back alone: the in-stem figure includes neighbours still ringing.
        alone, lags, seen, i, tp = verify(Path(sys.argv[sys.argv.index("--verify") + 1]))
        if alone > 0.5 / FPS or max(abs(x) for x in lags) > 0.002 or seen < len(PLACED) \
                or abs(i - TARGET_LUFS) > 0.7 or tp > CEILING_DBTP:
            sys.exit("soundtrack: verification failed")
    else:
        i, tp = master()
        print(f"{OUT.relative_to(ROOT)} · {len(PLACED)} events · {i:.1f} LUFS integrated · {tp:.1f} dBTP")
        if abs(i - TARGET_LUFS) > 0.7 or tp > CEILING_DBTP:
            sys.exit(f"soundtrack: missed the loudness target ({i:.1f} LUFS, {tp:.1f} dBTP)")
