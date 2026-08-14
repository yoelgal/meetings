<p align="center">
  <img src="brand/banner.png" width="720" alt="Meetings">
</p>

# Meetings

**An app for you. A CLI for your agent.**

A local-first meeting recorder and note-taker for macOS. It records your microphone and your Mac's
audio as two separate tracks, which is what tells you apart from everyone else in the transcript. It
transcribes them on device. Every note you type is anchored to the moment in the conversation you
typed it.

There are no prompts inside the app and no account. Write-ups happen in your own coding agent,
through the `meetings` command line tool and a bundled agent skill. The summary is steered by the
notes you took, not by someone else's template.

## Requirements

- macOS 26 or later. The app is built against APIs that do not exist earlier.
- Xcode 26 or its command line tools. `swift --version` should report 6.2 or later.
- About 1 GB of disk for the speech models. They download the first time transcription runs, into
  `~/Library/Application Support/FluidAudio/Models`. Nothing is bundled in the app.
- About 2 GB for the build itself, in `.build/`. Delete it any time.

## Build

```sh
./scripts/build-app.sh
mv dist/Meetings.app /Applications/
open /Applications/Meetings.app
```

The script fetches three dependencies (GRDB, swift-argument-parser, FluidAudio), builds in release
mode, assembles the bundle and signs it. A few minutes the first time, under a minute after that.

Two other scripts are worth knowing. `swift build` alone compiles the binaries without assembling an
app, which is faster while you are changing code. `scripts/verify.sh` runs the build, the test
suite, the app assembly and a smoke test of the shipped command line tool.

## Updating

Meetings asks GitHub once a day whether a newer release is tagged. If there is one, the foot of the
sidebar says so and links to the release notes. Turn it off in Settings › General.

It tells you rather than installing it, because there is no binary to install. You built this copy
from source and signed it with a certificate from your own keychain, so a downloaded replacement
would be a different app as far as macOS is concerned, and your microphone and screen recording
grants would reset. To update:

```sh
git pull
./scripts/build-app.sh
rm -rf /Applications/Meetings.app
mv dist/Meetings.app /Applications/
```

`rm -rf` first because `mv` will not overwrite a bundle. Your meetings are untouched by any of this.
They live in a separate directory, described below.

Updating does not re-ask for the microphone and screen recording, as long as you have a stable
signing certificate. The first build offers to create one. If you skipped it, run
`scripts/make-signing-identity.sh` and you will re-grant once more and then never again. The next
section explains why.

Releases are tagged `vMAJOR.MINOR.PATCH`. `build-app.sh` stamps the version into the bundle from the
tag, so a build off an untagged branch reports `0.0.0` and will always see a release as newer.

## The `meetings` command line tool

The tool is built into the app bundle, so it updates with the app. Settings › Command line has an
Install button that links it into `/usr/local/bin`. By hand:

```sh
sudo ln -s /Applications/Meetings.app/Contents/Helpers/meetings /usr/local/bin/meetings
meetings status
```

`meetings --help` lists the commands. Every one takes `--json`, and the exit codes are in the help
output because agents branch on them.

## The agent skill

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

Four things, and no others. There is no telemetry and no account.

1. **The speech models**, downloaded once from FluidAudio on first transcription. After that the app
   transcribes offline.
2. **The update check**, a daily request to GitHub's public release feed. It sends nothing about you
   or your meetings. Settings › General turns it off.
3. **Cloud write-up mode**, if you configure it. This sends your transcript and notes to the
   endpoint you set. Off by default.
4. **Local agent mode**, if you configure it. This runs your own coding agent on your transcript.
   Whether that stays on the machine depends on the agent, and most of them do not.

Recordings, transcripts and notes are never uploaded by the app itself.

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
