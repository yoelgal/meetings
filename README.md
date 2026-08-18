<p align="center">
  <img src="brand/banner.png" width="720" alt="Meetings">
</p>

# Meetings

**An app for you. A CLI for your agent.**

```sh
curl -fsSL https://raw.githubusercontent.com/yoelgal/meetings/main/install.sh | bash
```

That downloads the latest release, checks it against its published checksum and against the one
certificate every release is signed with, installs the app and the `meetings` command line tool,
installs the agent skill, and opens the app. About twenty seconds, and it never asks for your
password. Re-run it any time to update.

It needs macOS 26 on Apple Silicon and nothing else — no Xcode, no developer tools, no compiler. Read
it first if you would rather ([install.sh](install.sh)).

Meetings is not notarized, because notarization needs a paid Apple Developer account. Nothing asks
you to click past a security warning either: macOS only runs that check on files a *browser*
downloaded, and `curl` does not mark them. The app is signed with one certificate that never changes,
which is what lets macOS keep the microphone and Screen Recording permissions you grant it across
every future update. The installer checks that certificate itself, by a fingerprint written into
install.sh, so a release signed by anything else is refused rather than installed. What you can check
by hand, if you want to: the checksum published beside the download, and the build provenance
attestation on each release, which ties the binary to the commit and the workflow run that produced
it.

To build it from source instead — which is the same thing the installer used to do, and needs the
command line developer tools:

```sh
git clone https://github.com/yoelgal/meetings.git && cd meetings && ./install.sh --from-source
```

A local-first meeting recorder and note-taker for macOS. It records your microphone and your Mac's
audio as two separate tracks, which is what tells you apart from everyone else in the transcript. It
transcribes them on device by default, and can be pointed at a remote endpoint instead if you would
rather. Every note you type is anchored to the moment in the conversation you
typed it.

There are no prompts inside the app and no account. Write-ups happen in your own coding agent,
through the `meetings` command line tool and a bundled agent skill. The summary is steered by the
notes you took, not by someone else's template.

## Requirements

- macOS 26 or later, on Apple Silicon. The app is built against APIs that do not exist earlier, and
  the speech models are CoreML; there is no Intel build and the installer refuses one rather than
  pretending.
- About 640 MB of disk for the speech model. It downloads the first time transcription runs, into
  `~/Library/Application Support/FluidAudio/Models`. Nothing is bundled in the app.

Only if you build it yourself (`--from-source`, or the scripts below):

- Apple's command line developer tools, with the macOS 26 SDK — `xcode-select --install`, about
  1.5 GB, no Apple ID and no Xcode. `swift --version` should report 6.2 or later. A full Xcode works
  too, and if neither is installed `install.sh --from-source` offers to do it for you.
- About 2 GB for the build itself, in `.build/`. Delete it any time.

## Building it yourself

`install.sh --from-source` is a wrapper around these. Use them directly if you are working on the
code.

```sh
./scripts/build-app.sh          # build and assemble dist/Meetings.app
swift build                     # just the binaries, faster while iterating
scripts/verify.sh               # build, tests, assembly, CLI smoke run, install check
scripts/package-release.sh      # zip an assembled bundle into the release artifact
```

`build-app.sh` fetches three dependencies (GRDB, swift-argument-parser, FluidAudio), builds in
release mode, assembles the bundle and signs it. A few minutes the first time, under a minute after
that. It stamps the version from the git tag, so a build off an untagged branch reports `0.0.0`.

Nothing here is how a release is actually cut. That happens in `.github/workflows/release.yml` when a
`v*` tag is pushed: it runs `verify.sh`, signs with the project's distribution certificate, refuses
to continue if the result is not signed by exactly that certificate, packages, attests, and publishes
the GitHub Release the installer downloads from. The private key is not in this repo.

## Updating

Meetings asks GitHub once a day whether a newer release is published. If there is one, the foot of
the sidebar says so and hands you the command. Turn it off in Settings › General.

Updating is the install command again:

```sh
curl -fsSL https://raw.githubusercontent.com/yoelgal/meetings/main/install.sh | bash
```

It replaces the app in place and puts the old one back untouched if anything fails, so there is no
moment where the Mac has no Meetings. It refuses outright while a meeting is recording, and waits for
a running copy to quit before it swaps anything. Your meetings live in a separate directory and are
untouched by any of this.

Updating does not re-ask for the microphone or for Screen Recording. Every release is signed with the
same certificate, and macOS ties permissions to the signature rather than to the app's contents.

One exception, once: if you installed Meetings before it shipped as a prebuilt binary, your copy was
signed by a certificate created on your own Mac. The first prebuilt update is therefore a different
app to the permission system and both permissions are asked for again. The app explains this itself
when it happens and links straight to the right pane in System Settings. After that it never happens
again — unless you build from source, which signs with your certificate rather than the project's.

To pin an older release, or to go back after a bad one:

```sh
curl -fsSL https://raw.githubusercontent.com/yoelgal/meetings/main/install.sh | MEETINGS_VERSION=v0.3.0 bash
```

The variable goes on the right of the pipe, on `bash`. Put it in front of `curl` and it lands in the
downloader's environment, where the installer never sees it — the command then reinstalls the latest
release, which is the one you were trying to get away from.

Releases are tagged `vMAJOR.MINOR.PATCH` and published as GitHub Releases; the tag alone is not a
release, because the update check reads `/releases/latest`. A build off an untagged branch reports
`0.0.0` and will always see a release as newer.

## The `meetings` command line tool

The installer links this for you. It is built into the app bundle, so it updates with the app.

```sh
meetings status
```

If it is not on your PATH, Settings › Command line has an Install button, or link it by hand:

```sh
sudo ln -s /Applications/Meetings.app/Contents/Helpers/meetings /usr/local/bin/meetings
```

`meetings --help` lists the commands. Every one takes `--json`, and the exit codes are in the help
output because agents branch on them.

## The agent skill

The installer does this too, and the app re-runs it on every launch so it cannot go stale. By hand:

```sh
meetings skill install
```

This writes `SKILL.md` into `~/.claude/skills/meetings/`, and into the equivalent directory of any
other agent tool whose configuration directory already exists. It never creates one for a tool you
do not use. The skill teaches your agent the command surface, so "add a note to my call with Sam
tomorrow" works from any directory. It overwrites, keeping a `.bak` of anything you edited.

## Permissions

Meetings asks for nothing on its own. The setup guide on first launch offers each permission with a
button, and every one is reachable afterwards from Settings › Permissions.

**Microphone.** Your own voice. Asked for in the setup guide, or the first time you press Start.

**Screen Recording.** To record the other people on a call, Meetings has to capture the audio your
Mac is playing. The only macOS API that provides system audio is the screen-capture API, so the
permission is filed under Screen Recording and the dialog talks about your screen. Meetings never
records, displays or saves any picture of your screen. It asks for the sound. Decline and you get
your own microphone and half the conversation. macOS usually requires you to quit and reopen the app
after granting this one.

**Calendar.** Optional and read-only. Meetings reads Apple Calendar to show what is coming up, to
attach pre-meeting notes to the right event, and to learn attendee names so the transcriber spells
them correctly. Nothing in your calendar is created, edited or deleted. Without it the Upcoming list
says so and everything else works normally.

## What leaves your machine

Five things, and no others. There is no telemetry and no account.

1. **The speech models**, downloaded once from FluidAudio on first transcription. After that the app
   transcribes offline.
2. **The update check**, a daily request to GitHub's public release feed. It sends nothing about you
   or your meetings. Settings › General turns it off.
3. **Cloud write-up mode**, if you configure it. This sends your transcript and notes to the
   endpoint you set. Off by default.
4. **Local agent mode**, if you configure it. This runs your own coding agent on your transcript.
   Whether that stays on the machine depends on the agent, and most of them do not.
5. **Remote transcription**, if you choose it. The audio of every meeting is uploaded to the endpoint
   you configure. Nothing else about Meetings changes — notes, search and your write-up stay on this
   Mac — but the recordings themselves leave it. Off unless you pick it; on-device transcription is
   the other choice, and the first-run wizard asks.

Unless you turn one of those last three on, nothing about a meeting leaves this Mac: the app uploads
no recording, transcript or note of its own accord.

## Rebuilding re-asks for permissions, and how to stop it

macOS keys a permission to the app's code signature, not to its name or its path. Signed ad hoc, the
signature is a hash of the app's own code, so every rebuild is a stranger to the permission system
and your grants do not carry over. That applies to updates as much as to development.

The fix is a certificate that stays the same across builds. `build-app.sh` offers to set it up the
first time it would otherwise sign ad hoc, and you can run it yourself at any point:

```sh
scripts/make-signing-identity.sh
```

Nothing runs this for you. It explains what it will do to your keychain and asks first, `--dry-run`
prints the plan and stops, and it prints the one command that undoes it. macOS asks for your login
password once, when the certificate is marked as trusted. After that `build-app.sh` finds it
automatically. You re-grant permissions one last time on the next build and then they stick. To use a
certificate you already have, set `MEETINGS_SIGN_IDENTITY` to its name.

## Where your data lives

```
~/Library/Application Support/Meetings/
  store.db            SQLite: meetings, transcripts, notes, summaries, vocabulary
  store.db-wal        write-ahead log, part of the database, copy it too
  store.db-shm
  audio/<meeting-id>/ mic.wav and system.wav
  backups/            dated database snapshots
```

Audio is deleted 30 days after a meeting by default. Transcripts and notes are kept forever. The
speech models are cached separately under `~/Library/Application Support/FluidAudio/` and can be
deleted at any time, since they download again.

To back up, quit Meetings and copy the whole `Meetings` directory. Quitting first matters: the
`-wal` file holds recent writes that have not been folded into `store.db` yet, so copying `store.db`
alone from a running app can lose the last few minutes.

Two environment variables move the store, which is how the test suite runs without touching yours.
`MEETINGS_HOME` relocates the whole directory, `MEETINGS_DB` just the database file. The app and the
command line tool both honour them, so set them for both or neither.

## Licence

Meetings is [MIT licensed](LICENSE). Copyright © 2026 Yoel Gal.

Third-party code inside it keeps its own terms. [`NOTICE`](NOTICE) records them in full. Parts of the
microphone capture graph and the transcript segment grouping are derived from
[quill](https://github.com/digimata/quill) (MIT), and
[meetily](https://github.com/Zackriya-Solutions/meetily) (MIT) was an approach reference. The
packages SwiftPM fetches carry their own licences, see `Package.resolved` for exact versions. The
speech models are downloaded from FluidAudio's distribution at first run and are not redistributed
here.
