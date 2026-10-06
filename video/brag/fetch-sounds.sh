#!/usr/bin/env bash
#
# Fetches every recording the launch film's soundtrack is built from, and nothing else.
#
#   video/brag/fetch-sounds.sh        # into video/film/public/launch/sounds/ (ignored by git)
#
# All of it is CC0 (public domain) and all of it is a real recording — microphones on marbles,
# keys, switches, glass, a keyboard and a pen; a marimba, a grand piano and a contrabass played by
# people. No synthesis anywhere. Each line below names where it came from, so the licence of every
# sound in the film can be checked at its source.
#
# Instruments: the Versilian Community Sample Library (VCSL) and VSCO 2 Community Edition, both
# released by Versilian Studios under CC0 1.0 (github.com/sgossner/VCSL, /VSCO-2-CE).
# Objects: freesound.org sounds each marked "Creative Commons 0" by their author, fetched as the
# site's high-quality preview (128 kbps) — the original files need a login, the previews do not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/video/film/public/launch/sounds"
mkdir -p "$OUT"

fetch() {  # <name> <url>
    local name="$1" url="$2" tmp
    [ -f "$OUT/$name.wav" ] && return 0
    tmp="$(mktemp -t "sound.XXXXXX")"
    curl -sfL -A "Mozilla/5.0" "$url" -o "$tmp" || { echo "fetch: $name failed ($url)" >&2; exit 1; }
    # 48 kHz mono 16-bit: the rate the film's audio is mixed at, one channel because every sound
    # is placed in the stereo field by the mix rather than by however it was miked.
    ffmpeg -loglevel error -y -i "$tmp" -ac 1 -ar 48000 -c:a pcm_s16le "$OUT/$name.wav"
    rm -f "$tmp"
    echo "    $name"
}

vcsl() { echo "https://raw.githubusercontent.com/sgossner/VCSL/master/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; }
vsco() { echo "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/master/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; }

# Marimba (VCSL, Idiophones/Struck Idiophones/Marimba), medium dynamic.
for n in G2 B2 F3 C4 G4 B4 F5 C6; do
    fetch "marimba_$n" "$(vcsl "Idiophones/Struck Idiophones/Marimba/Marimba_hit_Outrigger_${n}_med_01.wav")"
done
# Grand piano (VCSL, Kawai), second velocity layer.
for n in A2 C3 B3 A4 C5; do
    fetch "piano_$n" "$(vcsl "Chordophones/Zithers/Grand Piano, Kawai - Legacy/Sustains/GrandPno_Main_Sus_${n}_v2_rr1.wav")"
done
# Solo contrabass, pizzicato (VSCO 2 CE).
for n in C1 D1 E1 F#1 G#1 A1 C#2 E2; do
    fetch "pizz_$n" "$(vsco "Strings/Solo Contrabass/Pizz/BKCtbss_Pizz_${n}_v1_rr1.wav")"
done

# freesound.org, CC0. id · author · what it is.
fetch marble_desk   https://cdn.freesound.org/previews/240/240313_3624044-hq.mp3   # 240313 D.S.G. — a marble dropped on a desk
fetch marble_tile   https://cdn.freesound.org/previews/532/532149_5911297-hq.mp3   # 532149 patchytherat — marble dropped on tile
fetch marble_table  https://cdn.freesound.org/previews/458/458137_7254624-hq.mp3   # 458137 NeatoEnt — marbles dropped on a hard table
fetch keys_pickup   https://cdn.freesound.org/previews/267/267711_3666787-hq.mp3   # 267711 WeeJee_vdH — car keys picked up, studio
fetch keys_jingle   https://cdn.freesound.org/previews/565/565909_6371307-hq.mp3   # 565909 Fenodyrie — 14 old keys, Zoom H2
fetch switch_light  https://cdn.freesound.org/previews/257/257958_3025911-hq.mp3   # 257958 FillSoko — light switch on/off
fetch switch_flick  https://cdn.freesound.org/previews/566/566176_10435241-hq.mp3  # 566176 — flicking a switch
fetch glass_bottles https://cdn.freesound.org/previews/416/416288_6857156-hq.mp3   # 416288 Fugeni — two empty bottles tapped, AT2035
fetch glass_window  https://cdn.freesound.org/previews/406/406261_5923045-hq.mp3   # 406261 Anthousai — window hit with a wooden spoon, DR-40
fetch glass_place   https://cdn.freesound.org/previews/353/353105_6220210-hq.mp3   # 353105 milpower — glass bottle set on a glass plate
fetch keyboard_mech https://cdn.freesound.org/previews/450/450282_9373288-hq.mp3   # 450282 stu556 — mechanical keyboard (MX browns)
fetch pen_click     https://cdn.freesound.org/previews/235/235563_2756248-hq.mp3   # 235563 SkeetMasterFunk69 — pen clicking
