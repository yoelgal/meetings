# Meetings: launch film plan

**What it is.** A local-first meeting recorder for macOS. It records your mic and your Mac's audio
as two separate tracks, transcribes on device, anchors every note you type to the moment it was said,
and hands the write-up to your own coding agent through a CLI.

**Who it's for.** People on lots of calls who already live in an agent (Claude Code and friends) and
don't want a SaaS bot joining their meetings or their audio leaving the Mac.

**What sets it apart.** Two tracks: it knows who said what without guessing from one mixed recording.
No prompts in the app and no account. The write-up is your agent's job, steered by your notes.

**Most impressive claim.** It never confuses you with them, because "you" is literally a different
microphone track. Runner-up: the notes panel is invisible on a screen share.

**Visual hook.** A transcript line with no speaker: *"I'll send it by Friday."* Then: *Who said that?*

**Tone.** `yc-parody` played straight → freeform: a crisp YC Launch film. Confident, dry, one claim
per beat, hard cuts on the beat, real UI the whole way through the middle. Dark, the app's own blue
(mic / You) and pink (system / Others) as the only accents.

**Share caption.** "Meetings records you and everyone else as two separate tracks, so the transcript
always knows who said it. On-device, notes pinned to the moment, and a CLI so your agent writes it up."

## Visual identity
- Background near-black navy (`#05041a` → `#100d33`), the README banner's palette.
- Inter (OFL) for all type: San Francisco's licence forbids use in a video. JetBrains Mono for the terminal.
- Accents: systemBlue `#0A84FF` = You (mic), systemPink `#FF375F` = Others (system), from `ChannelStyle.swift`.
- App footage: the real app (dark), captured by `video/brag/shoot.sh` from a throwaway store of invented data.

## Storyboard (34 s, 1920×1080, 60 fps; cuts from 6.6 s on sit on the 0.6 s beat)

| # | t | Scene | On screen | Motion / cut |
|---|---|---|---|---|
| 1 | 0.0–3.0 | **Hook** | A lone transcript line types in: `"I'll send it by Friday."` → beat → big: **Who said that?** | Type-on, then hard cut to the question on the downbeat |
| 2 | 3.0–6.6 | **Problem** | One grey waveform. "Most recorders hear one mixed track." → "Then they guess who's talking." | Waveform pulses; second line replaces the first |
| 3 | 6.6–10.2 | **Reveal** | The waveform splits into two: blue **You** (mic) / pink **Others** (Mac audio). Logo + "Meetings records them separately." | Split animation, logo snaps in |
| 4 | 10.2–16.2 | **Live, on device** | Real app: recording view, live transcript lines arriving in blue/pink. Caption: "Transcribed live. On this Mac." | Window slides up, slow push-in on the transcript |
| 5 | 16.2–20.4 | **Anchored notes** | Real app: a written meeting with Your notes + Transcript open. Caption: "Every note lands where it was said." | Pan from notes to transcript |
| 6 | 20.4–24.6 | **Hidden from screen share** | Split: "Your screen" (app + floating notes panel) / "What they see" (app, no panel). Caption: "Your notes stay off the screen share." | Panel fades out of the right half |
| 7 | 24.6–30.0 | **A CLI for your agent** | Terminal card typing a real `meetings` session over the app, then the real write-up landing in the window. Caption: "No prompts in the app. Your agent writes it up." | Terminal over app, scrim, then the write-up clip |
| 8 | 30.0–34.0 | **End card** | Logo + **Meetings**, "An app for you. A CLI for your agent.", the install line in mono, "macOS 26 · Apple Silicon · MIT" | Hero reveal, hold |

Readability: every caption holds ≥ 0.3 s/word after settling. Hook line holds 1.2 s before the question.

## Sound
Real recordings only, all CC0, fetched by `video/brag/fetch-sounds.sh` (sources listed there):
- **Every cut and click its own object:** marbles on a desk, a table and tile; car keys; a light
  switch; bottles, a window and a plate of glass; a mechanical keyboard (one key per typed
  character); a pen click (each answer the terminal prints, and your lines in the transcript).
- **Melody:** marimba (VCSL), grand piano (VCSL), contrabass pizzicato (VSCO 2 CE), A minor,
  100 BPM, re-pitched by resampling only.
- **Timing:** event times come from `timing.json` (which Launch.tsx draws from), the same frame
  formulas the type-on uses, and the captured clips' own frame changes. Each recording is aligned by
  its detected attack; fades are placed on the frame they become visible, measured from a silent
  render. `video/brag/finish.sh` renders, mixes, muxes and then verifies: attack vs frame, codec
  delay, picture change per event, integrated and short-term loudness (`soundtrack-report.txt`).
