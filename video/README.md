# The product demo

A 30-second Loom-style demo of Meetings, built from the real app, cut as **one continuous shot**. Two
commands:

```sh
video/shoot.sh                  # capture the footage
cd video/film && bun run render # cut and encode it
```

Out comes `video/film/out/meetings-demo.mp4`. Read [`NOTICE`](NOTICE) first if you are not a solo
developer: the compositor is Remotion, which is source-available rather than open source and is free
only for individuals and companies of three or fewer.

`bun run audit` reports what the camera is doing and fails if any change of picture is not hidden by
it. `render` and `master` both run it first — see [The camera](#the-camera).

## The data is invented

Every person, company, meeting and line of dialogue in this demo is made up, and every address is
under `example.com` or `.example`, which RFC 2606 reserves so a fixture can never name a real mailbox.
Nothing in it comes from anybody's real store. The demo store is seeded fresh under `/tmp` on every
run and the operator's own meetings and calendar are never read or written.

## What is actually on screen

Every frame of app footage is the shipping app, running against that throwaway store, photographed
without anybody touching the keyboard or the mouse. Nothing is a mock-up or a redraw.

- **The window states are posed with the launch-time overrides in `Appearance`** (`MEETINGS_SCOPE`,
  `MEETINGS_SELECT`, `MEETINGS_SEARCH`, `MEETINGS_DETAIL_OPEN`, `MEETINGS_RECORDING_CHROME`, …),
  which exist so a window can be photographed in a given state without being clicked. Nothing is
  activated, raised, focused, moved or resized.
- **The two clips are the app reacting to a real write.** The store posts a change notification on
  every commit and the window refreshes itself, whichever process did the writing. So `clips/live.mov`
  is recorded while six transcript segments are inserted from outside the app, about 1.3 s apart, and
  `clips/writeup.mov` while `meetings summary set` runs at the command line — which is why the write-up
  appears, and its actions become tickable checkboxes, with no cursor anywhere near them.
- **The demo content is written through `MeetingStore`**, so the search index, the note anchors and the
  `- [ ]` task items are real. `meetings search "pricing"` finds what the demo shows it finding.

**The cursor is drawn, and that is deliberate rather than a shortcut.** See below.

## Why the cursor is synthetic

A Loom normally records a real pointer. Every way of moving one on macOS 26 — `CGEventPost`,
`cliclick`, Hammerspoon, or an accessibility `AXPress` — needs a TCC grant that prompts, and injects
into the session-global HID stream, which means seizing the pointer and keyboard of whoever is using
the Mac. This app's own source already names and rejects both routes, in
`Sources/MeetingsApp/MeetingsApp.swift`:

> the only alternatives are resizing the window with the mouse or through the accessibility API: the
> first takes the operator's pointer, the second needs a permission nothing here may ask for.

So `wincap.swift` records with `showsCursor = false` and the pointer is composited afterwards. That is
also how Screen Studio and Cap work: both re-time and smooth the cursor in post, which is impossible
once it has been baked into the pixels. One authored keyframe list per beat drives the cursor, the
click punch **and** the camera, so they cannot drift apart from each other or from the UI.

## One continuous shot

The demo has no beats and no cuts. There is one camera, solved once over the whole thirty seconds, and it
never comes to a halt except while the terminal is open in front of the app.

That is the single biggest thing in here, and it took three tries. The first cut was seven beats edited
together; the second cross-dissolved them. Both read as a slideshow, for two reasons that had nothing to
do with the transitions: each beat reset the camera to rest, so the motion stopped seven times, and seven
captions appeared and disappeared, drawing a boundary around each one. The captions are gone. The camera
is one move.

It cannot be a *literal* single take. The app's window states are applied at launch — `MEETINGS_SCOPE` and
friends are read once — and this repo refuses to synthesise the clicks that would navigate a running
instance, for the reason in the section above. So five separate captures are dissolved into one unbroken
window rect, and the whole trick is **where**:

- Each swap lands in a *release* — the ~600 ms while the camera is pulling back out of a zoom and the whole
  picture is shrinking by 30–45 px per frame.
- The dissolve is **300 ms**, and the window **blurs to 11 px** across it, peaking exactly where both
  layers sit at half opacity.
- The chrome is in the same place at the same scale on both sides of it, because both shots live in one
  rect that only the camera moves.

Getting that wrong is silent, so it is measured rather than eyeballed. `bun run audit` solves the same
camera from the same data and prints its speed through every swap:

```
    at        shot                    pan      zoom     total   cover
  3.85s   clips/live.mov           5.1    35.5    40.6   motion
  13.40s   clips/writeup.mov        0.0     0.0     0.0   scrim
  19.70s   shots/search.png        18.5    27.5    46.0   motion
  23.60s   shots/upcoming.png       0.0    28.2    28.2   motion

  camera moves: 5 — 0.90–3.70s, 4.70–11.90s, 14.50–19.50s, 20.60–23.40s, 24.50–27.30s
  at rest for 5.5s of 29.9s
```

It exits non-zero below 6 px/frame, and `render` and `master` run it first. It has already caught two
mistakes that looked fine in the source and would have shipped: keyframes placed on the swap rather than
bracketing it, which parked the camera at 1.7 px/frame, and a swap mid-pan while zoomed, which was moving
plenty but showed two readable layouts ghosted over each other.

The one swap with no camera cover is the write-up, which changes behind the terminal's scrim. `ffmpeg`'s
scene detector finds **zero** hard cuts in the result, same as the reference.

## The framing

Measured off a reference demo rather than chosen. The window fills the frame: ~44 px of backdrop on each
side, not 300. It is captured at **1600×900** so 16:9 matches the frame and the padding is even on all four
sides.

The backdrop is a bright wallpaper for the same reason — the reference's corners sample `#f7eaca`,
`#8489fe`, `#87bffb`, `#a9abf8`. A dark app on a dark backdrop has nothing to sit on, and the padding reads
as a mistake instead of a frame. It is a gradient rather than the real desktop wallpaper, because a
wallpaper is the operator's and this demo carries nothing of theirs.

The closing card is the README banner: the repo's own `brand/logo.png`, with the name beside it, on a card
that fades to near-black first. The mark is opaque with its bloom baked in, so it is composited with
`screen` — and masked, because measuring the source showed its glow is clipped by the square it is drawn
in (corners read `#01032d`, the middle of the top edge `#250c67`), which put a visible rectangle around it.

## The camera

The zoom is not authored. It is *derived* from the clicks in the pointer track, using the law Cap ships
(read out of `crates/rendering` and `crates/project`; the numbers are facts, the code is AGPL and was not
copied):

| Behaviour | Value |
|---|---|
| Zoom amount | `1.42×` — **not** Cap's 2.0, and not the 1.75 an earlier cut used; see below |
| Segment around a click | `−300 ms` → `+2500 ms` |
| Merge two segments if the gap is | `≤ 900 ms` — Cap ships 2500; see below |
| Clamp the last segment to end before | `800 ms` from the end |
| Camera spring | ω₀ 11 rad/s, **ζ = 1** (settles ≈ 430 ms, cannot overshoot) |
| Cursor spring | ω₀ 14 rad/s, **ζ = 1** (lag ≈ 70 ms) |
| Click | scale punch to `0.8` over `130 ms`, smoothstep — no ripple |
| Keystroke pill | 50 px, black at 95%, `150 ms` fade with a 6 px bounce |

**Two of Cap's numbers do not transfer, and both bit before they were understood.**

*Zoom amount* has to be re-derived whenever the card's resting size changes. Cap's 2.0 is relative to a
recording that fills the frame. When the card was 1312 px wide, 1.75 magnified the app by 1.59×. Once the
card grew to 1832 px to fill the frame, that same 1.75 rendered it 3206 px wide — *1:1 with the 2× capture*,
the app at its true retina size, 54% of the window on screen. It read as a crop of a screenshot rather than
a camera, and it was what made the dissolves ghost: at that scale both layers are readable. 1.42 shows ~68%
of the window and renders the app's 13 pt text at ~10 px.

*Merge gap* of 2500 ms, with the lead and tail either side, merges any two clicks less than **5.3 seconds**
apart. That is right for a recording of real work, where a pump between two nearby clicks is a fault. In a
thirty-second film with six features it merged every click into one unbroken hold and the camera never came
back out — and it has to come back out, because the release is the only place a change of picture is
invisible. Cap is recording one continuous session and has nothing to hide. At 900 ms the merge still does
its job inside a feature (clicks within ~3.7 s) and releases between them.

**Both springs are critically damped, and that is the fix for "bouncy".** Cap ships ζ ≈ 0.94, which is
underdamped; a spring answering a *step* target must then overshoot, so the camera pushed past its mark
and settled back. At ζ = 1 the approach is monotonic. Verified numerically rather than by eye: peak
overshoot is one part in 10¹⁵ and the zoom curve has exactly one velocity sign change per move.

Speed and bounce are separate knobs — ω₀ sets how fast it settles, ζ whether it rings. `spring.ts` takes
them that way round for exactly that reason.

Two consequences worth knowing before editing `plan.ts`. Click spacing is the *only* control over the
camera's rhythm: bunch clicks inside a feature to hold a zoom on it, spread them between features to make
it release. And a keyframe is an **arrival** time, not a departure — the move happens in the interval
*before* it, which is why every swap is bracketed by a keyframe on each side rather than sitting on one.

## Layout

```
video/
  shoot.sh              seeds the store, poses the window, captures stills and clips
  seed/                 SwiftPM package that writes the demo store (depends on MeetingsCore)
  capture/
    wincap.swift        one window -> ProRes 4444 with alpha, 60fps, no cursor
    winlist.swift       the windows a bundle id owns, for finding the one just launched
  film/
    src/plan.ts         the window states, the pointer path and the overlay timings — the demo, as data
    src/Demo.tsx        the assembly: backdrop, stage, two overlays
    src/loom/           the Loom camera: spring solver, zoom law, cursor, pill, terminal, closing
    src/theme.ts        frame rate and the window shadow
    scripts/            font copy, colour tagging, and the camera audit
    public/             generated: shots/, clips/, brand/, fonts/
```

## Why these tools

**Remotion** for the composition. It is already here, it gives frame-exact compositing of the ProRes
clips, and Chrome's compositor renders type and shadows far better than a raster pipeline.

**ScreenCaptureKit** for the footage, via `capture/wincap.swift`, because `screencapture -v` on macOS
26 cannot do it: its video mode takes a display or a rectangle and has no frame rate, codec or
cursor-exclusion flag at all.

Considered and rejected: **Cap** (AGPL; real CLI, but a Tauri app whose studio effects are not a
library) and **screenstudio-alt** (MIT, genuinely headless, and it does work — but its raster output
bands the gradient and sets type in the system sans, and it would add Python plus a second video
engine to a repo that already has one). **Kap** has had no release since 2022. **Motion Canvas** has
had no code commit since early 2025.

**No music.** The demo is cut so a track can be laid under it, but none is committed here because
there is none whose licence this repository can vouch for.

## Re-shooting

`shoot.sh` builds the app bundle, the seeder and the capture tools each time; `--no-build` skips all
three. It works in `/tmp/meetings-film` and runs a separate app bundle
(`com.yoelgal.meetings-film`), because two running apps may not share a bundle identifier — the second
gets no window at all, and your own Meetings is probably open.

```sh
video/shoot.sh --no-build
cd video/film
bun run studio     # scrub the edit and tune the tracks
bun run render     # 1920x1080 H.264, ~10 MB
bun run master     # 3840x2160 ProRes 422 HQ
```

`scripts/vidkeys.sh video/film/out/meetings-demo.mp4 /tmp/keys 6 low` prints one still per state
change with how long the demo held it, which is the quickest way to audit a cut's pacing.
