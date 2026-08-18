import AVFoundation
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Security
import MeetingsCore
import SwiftUI

/// What this build calls itself.
///
/// `build-app.sh` stamps `CFBundleShortVersionString` from the git tag, so this is the string the
/// update check compares against GitHub's latest release. The fallback matters: a `swift run` with
/// no bundle around it, or a build from an untagged tree, has no version to compare, and `0.0.0`
/// makes that read as "older than everything" rather than crashing or claiming to be current.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// The checkout this build was assembled from, stamped by `build-app.sh`. Nil for a `swift run`
    /// with no bundle around it.
    static var sourceRoot: String? {
        Bundle.main.object(forInfoDictionaryKey: "MeetingsSourceRoot") as? String
    }

    /// The one line that updates this install, ready to paste.
    static var updateCommand: String { updateCommand(sourceRoot: sourceRoot) }

    /// The update notice used to only link to the release page, which is where a person then stood
    /// reading what changed with no idea what to type. A build assembled from a checkout has one
    /// answer — a pull and a rebuild — and the only unknown is the directory, which the bundle knows.
    ///
    /// The fallback is the README's own one-liner, which installs or updates in place, so the notice
    /// is never reduced to a shrug. It is also the branch **every downloaded copy takes**: a prebuilt
    /// release carries no `MeetingsSourceRoot`, because it was not assembled from a checkout on this
    /// Mac. That is why the source root is a parameter rather than read inside here — the branch a
    /// test needs to pin depends on an Info.plist key belonging to whatever bundle the test process
    /// happens to be running inside, which no test can change, so the half that most users see was
    /// the half nothing covered.
    static func updateCommand(sourceRoot: String?) -> String {
        guard let root = sourceRoot else {
            return "curl -fsSL https://raw.githubusercontent.com/"
                + "\(UpdateCheck.repository)/main/install.sh | bash"
        }
        // Quoted, because a path with a space in it is otherwise two arguments and the command a
        // person pastes silently cds somewhere else.
        return "cd '\(root.replacingOccurrences(of: "'", with: #"'\''"#))' && git pull && ./install.sh"
    }
}

/// What signed this build, which decides whether the permissions you grant survive the next update.
///
/// macOS keys a TCC grant to the app's code signature. An ad-hoc signature *is* a hash of the app's
/// own code, so the next build is a different app to the permission system and every grant is asked
/// for again. Nothing in the app said so: you granted the microphone, updated a week later, were
/// asked again, and the only explanation was in a README section about code signing.
///
/// A named certificate keys the grant to the *certificate* instead — the Designated Requirement reads
/// `identifier "…" and certificate leaf = H"<sha1>"` — so the grants outlive every rebuild signed by
/// the same identity, and are reset by a build signed by a different one.
///
/// Each answer is read once and cached. A running process cannot change its own signature, and the
/// dictionary the read produces cannot be cached itself — `[String: Any]` is not `Sendable`, so a
/// shared `static let` holding one is a data race the compiler rejects.
enum CodeSignature {
    static let isAdHoc: Bool = {
        // False when the read itself fails, so an unexpected answer from the Security framework
        // leaves the app quiet rather than telling someone their perfectly-signed build is about to
        // lose their permissions.
        guard let dictionary = signingInformation() else { return false }
        // An ad-hoc signature carries no certificate chain. Any named identity, self-signed or a
        // real Developer ID, puts at least one certificate here.
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [Any]
        return certificates?.isEmpty ?? true
    }()

    /// The identity this build was signed by, as the leaf certificate's SHA-1 in lowercase hex — the
    /// same string `codesign -s <hash>` takes and the same one `Packaging/distribution-cert.sha1`
    /// holds, so a recorded value can be read against the release identity by eye.
    ///
    /// The fingerprint rather than the subject name because the name is not unique: every Mac that
    /// ran `scripts/make-signing-identity.sh` minted its own certificate under the same common name,
    /// and those are different identities to TCC. Nil for an ad-hoc signature, which has no
    /// certificate to fingerprint, and nil when the signature cannot be read at all.
    static let signingIdentity: String? = {
        guard let dictionary = signingInformation(),
              let chain = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        // SHA-1 because that is what the signing tools and the Designated Requirement speak. It is
        // compared against a value this same code wrote rather than used to authenticate anything, so
        // the collision weakness that rules SHA-1 out elsewhere does not apply.
        return Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }()

    /// Nil when the signature could not be read at all, which is a different answer from a signature
    /// that carries no certificates, and both callers above depend on the difference.
    private static func signingInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
}

/// The one launch on which macOS forgets every permission you granted, and whether to say so.
///
/// Meetings used to be compiled on the machine it runs on and signed by a certificate minted there,
/// so each install had an identity of its own. A prebuilt release is signed by one shared
/// distribution certificate, which is what makes the grants survive future updates — but the update
/// that introduces it changes the signature, so on that one launch TCC's grants are gone and macOS
/// asks for the microphone and for Screen & System Audio Recording again. An unexplained permission
/// prompt after an update reads as a bug, or as malware.
///
/// So the identity is recorded on every launch and compared against the last one. UserDefaults rather
/// than the settings table because it is a fact about this bundle on this Mac — nothing the CLI or an
/// agent has any business reading — which is the same call the notes panel makes for window state.
enum SigningChange {
    /// What the last launch was signed by, and whether an explanation is still owed. Two keys rather
    /// than one because the notice outlives the launch that raised it: by the time somebody reads it
    /// the new identity has long been recorded, so the flag is the only thing left that remembers.
    static let identityKey = "MeetingsSigningIdentity"
    static let noticeKey = "MeetingsSigningChangeNoticePending"

    /// Records the running signature and answers whether the notice is owed.
    ///
    /// Recording and comparing are one call because the record has to be written on the launch that
    /// raises the notice too. Written only when nothing changed, a migrated user would be told again
    /// every launch forever; and the notice has to survive being quit on rather than dismissed,
    /// because the permission prompts arrive at the first recording, which may be days later — so the
    /// answer is a flag that only the notice's own buttons clear, not a fresh comparison each launch.
    ///
    /// Two things raise it, and the second exists because the first cannot cover the migration this
    /// was built for. No shipped build ever recorded an identity, so the launch that introduces the
    /// prebuilt certificate has nothing to compare against and would pass in silence — the one launch
    /// where the grants are definitely gone.
    ///
    /// 1. A recorded identity that differs. Any later rotation of the distribution certificate, on a
    ///    downloaded copy or a from-source one, because a rotation resets the grants either way.
    /// 2. Nothing recorded, but this Mac has finished setup before *and* this copy was downloaded
    ///    rather than compiled here.
    ///
    /// Both halves of (2) are load-bearing. Without `usedBefore` a genuine first launch opens with an
    /// apology for revoking permissions it was never granted, talking over the setup wizard. Without
    /// `isPrebuilt` the notice is a lie told to a `--from-source` user, who rebuilt with their own
    /// local certificate and lost nothing: `MeetingsSourceRoot` is stamped by every build assembled
    /// from a checkout and stripped by `MEETINGS_RELEASE=1`, so its absence is exactly "this copy was
    /// downloaded".
    static func recordAndDetect(
        identity: String? = CodeSignature.signingIdentity,
        usedBefore: Bool,
        isPrebuilt: Bool = AppInfo.sourceRoot == nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        // No readable identity is no evidence either way, and overwriting the record with nothing
        // would make the *next* launch of a signed build look like a first launch and swallow the
        // notice. An already-owed one still shows.
        guard let identity else { return defaults.bool(forKey: noticeKey) }
        let previous = defaults.string(forKey: identityKey)
        defaults.set(identity, forKey: identityKey)
        if let previous {
            if previous != identity { defaults.set(true, forKey: noticeKey) }
        } else if usedBefore, isPrebuilt {
            defaults.set(true, forKey: noticeKey)
        }
        return defaults.bool(forKey: noticeKey)
    }

    /// One explanation is the whole point, so acting on it counts as having read it.
    static func dismissNotice(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: noticeKey)
    }

    /// Where the Screen Recording toggle lives. The microphone arrives as a dialog you answer without
    /// leaving the app; this grant is a checkbox in a pane several levels into System Settings, and
    /// finding it unaided is the actual friction in the migration.
    ///
    /// Resolved through ``Permission`` rather than spelled again, because the permission rows already
    /// hold the same URL and two copies of a URL scheme nobody can typo-check is how one of them ends
    /// up opening the wrong pane.
    static var screenRecordingSettings: URL? { Permission.systemAudio.settingsURL }
}

/// Said where permissions are, because that is the only place someone is thinking about them.
///
/// No button: the fix is a script in the repository this app was built from, and the app has no idea
/// where that is. The command is the whole content, so it is selectable and one press to copy.
struct AdHocSigningNotice: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Text("These permissions will be asked for again after every update")
                    .font(.callout.weight(.medium))
            }
            Text("This copy of Meetings is signed ad hoc, so macOS sees each new build as a "
                + "different app. Run this once in the folder you built it from and the grants "
                + "stick from then on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(Self.command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10, style: .continuous))
    }

    private static let command = "scripts/make-signing-identity.sh"
}

/// Updating the app from inside the app: pull, rebuild, reinstall, reopen.
///
/// It hands the work to Terminal rather than doing it in-process, for two reasons that are really
/// one. The app has to be **replaced while it is not running** — `install.sh` kills it before it
/// moves the new bundle into place — so whatever drives the update cannot be the app. And a rebuild
/// is a couple of minutes of compiler output; run invisibly, that is two minutes of a quit app and
/// no evidence anything is happening, which is indistinguishable from a crash.
///
/// So the button opens a Terminal window on a script. You watch it build, and it reopens Meetings at
/// the end. `open -a Terminal <script>` rather than AppleScript deliberately: driving Terminal by
/// AppleScript needs the Automation permission, and asking for a fourth permission so the app can
/// update itself is a bad trade.
enum SelfUpdate {
    /// Only when there is still a checkout to update. A bundle whose source was moved or deleted
    /// gets the copyable command instead, which at least tells the truth.
    static var isPossible: Bool { script != nil }

    /// The command a person can run by hand, and the one the script runs.
    static var command: String { AppInfo.updateCommand }

    static func run() -> String? {
        guard let source = script else { return "Cannot find the folder this copy was built from." }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-update-\(UUID().uuidString).command")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
            // .command opens in Terminal and runs; the executable bit is what makes it run rather
            // than open in a text editor.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return "Could not write the update script. \(error.localizedDescription)"
        }
        NSWorkspace.shared.open(url)
        return nil
    }

    private static var script: String? {
        guard let root = AppInfo.sourceRoot else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root + "/.git"),
              fm.isExecutableFile(atPath: root + "/install.sh") else { return nil }
        let quoted = root.replacingOccurrences(of: "'", with: #"'\''"#)
        return """
            #!/bin/bash
            # Written by Meetings. Safe to delete.
            set -euo pipefail
            cd '\(quoted)'
            echo "Updating Meetings in $(pwd)"
            echo
            # --ff-only, never a merge: this is someone pressing a button, not resolving a conflict.
            # Local commits or a dirty tree stop here with git's own message, which is more use than
            # anything this script could invent.
            git pull --ff-only
            ./install.sh
            echo
            echo "Done. This window can be closed."

            """
    }
}

/// The three permissions Meetings needs, reported without ever asking for one.
///
/// Every `status` call here is a pure read: `AVCaptureDevice.authorizationStatus`,
/// `CGPreflightScreenCaptureAccess` and `EKEventStore.authorizationStatus` all answer from TCC's
/// database without putting a dialog on screen. The `request` calls are the only things that
/// prompt, and nothing calls them except a button the user pressed.
enum Permission: String, CaseIterable, Identifiable {
    case microphone, systemAudio, calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        case .calendar: "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .systemAudio: "speaker.wave.2"
        case .calendar: "calendar"
        }
    }

    /// The screen-recording permission is confusing because macOS calls it "screen
    /// recording" for what is, here, audio only. Say so ourselves rather than letting the OS dialog
    /// do the talking.
    var explanation: String {
        switch self {
        case .microphone:
            "Your own voice. Recording starts only when you press Start, and the audio never "
                + "leaves this Mac."
        case .systemAudio:
            "Everyone else on the call. macOS files this under Screen Recording because system "
                + "audio is only available through the screen-capture API. Meetings never records "
                + "or saves a picture of your screen. Approving it means audio only."
        case .calendar:
            "Read-only. Lets Meetings list what is coming up, attach pre-notes to the right "
                + "event, and spell attendee names correctly."
        }
    }

    /// Where System Settings opens if the user has already said no — the only way back from a
    /// denial, because TCC never prompts twice.
    var settingsURL: URL? {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .systemAudio: "Privacy_ScreenCapture"
        case .calendar: "Privacy_Calendars"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }

    /// A read. Never prompts, from any of the three.
    var status: PermissionStatus {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .denied: .denied
            case .restricted: .denied
            case .notDetermined: .notDetermined
            @unknown default: .notDetermined
            }
        case .systemAudio:
            // Preflight, not request: it answers from TCC and puts nothing on screen. There is no
            // three-way answer available here — the API only tells you yes or not-yes.
            CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .calendar:
            switch EventKitCalendarSource().authorizationStatus() {
            case .authorized: .granted
            case .denied, .restricted: .denied
            case .notDetermined: .notDetermined
            }
        }
    }

    /// Every permission read at once. One call so the two places that show these rows cannot drift.
    static func snapshot() -> [Permission: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.status) })
    }

    /// The only thing in the app that can raise a system permission dialog, and it runs only from a
    /// button press.
    @discardableResult
    func request() async -> PermissionStatus {
        switch self {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .systemAudio:
            _ = CGRequestScreenCaptureAccess()
        case .calendar:
            _ = try? await EventKitCalendarSource().requestAccess()
        }
        return status
    }
}

extension View {
    /// Re-reads all three permissions every time the app comes back to the front.
    ///
    /// The rows are a snapshot taken in `onAppear`, and pressing "Allow…" is not what changes two
    /// of them. `CGRequestScreenCaptureAccess` returns immediately — it opens System Settings and
    /// does not wait for you — so the status written back is the one from *before* the grant, and
    /// nothing ever asks again. The row that sent you to System Settings then still reads "Not
    /// asked yet" when you come back, which looks like the app failing rather than the display
    /// being stale. Leaving for System Settings and returning is a deactivate/activate pair, so
    /// that is the moment to look again.
    func refreshingPermissions(into statuses: Binding<[Permission: PermissionStatus]>) -> some View {
        onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            statuses.wrappedValue = Permission.snapshot()
        }
    }
}

enum PermissionStatus {
    case granted, denied, notDetermined

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not asked yet"
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "circle.dashed"
        }
    }
}

/// Symlinks the bundled CLI to `/usr/local/bin/meetings`, VS Code style.
///
/// The binary lives at `Meetings.app/Contents/Helpers/meetings` and **not** `Contents/MacOS`,
/// because this volume is case-insensitive and `MacOS/meetings` would silently overwrite the app
/// executable `MacOS/Meetings`.
enum CLIInstall {
    static let destination = URL(fileURLWithPath: "/usr/local/bin/meetings")

    /// The CLI inside this app bundle. Nil when running from `swift run`, where there is no bundle
    /// to link to and the honest answer is that there is nothing to install.
    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/meetings")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    enum Status {
        case installed
        /// Something is at the destination, but it is not this app's CLI.
        case foreign(String)
        case missing
        /// Running outside a `.app`, so there is nothing to link.
        case unavailable

        var label: String {
            switch self {
            case .installed: "Installed at /usr/local/bin/meetings"
            case .foreign(let path): "/usr/local/bin/meetings points at \(path)"
            case .missing: "Not installed"
            case .unavailable: "Only available in the built app"
            }
        }
    }

    static func status() -> Status {
        guard let bundled = bundledCLI else { return .unavailable }
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return .missing }
        let resolved = destination.resolvingSymlinksInPath().path
        return resolved == bundled.resolvingSymlinksInPath().path ? .installed : .foreign(resolved)
    }

    /// Returns nil on success, or a sentence explaining what to do instead.
    ///
    /// `/usr/local/bin` is root-owned on a clean install, and this app is deliberately not going to
    /// raise an authorisation dialog behind your back to get around that. When the link cannot be
    /// made, the exact one-line command is handed over instead — which is also the honest answer
    /// for anyone who would rather see what is about to happen to their `/usr/local`.
    static func install() async -> String? {
        guard let bundled = bundledCLI else {
            return "The CLI ships inside Meetings.app. Build the app with scripts/build-app.sh first."
        }
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.createSymbolicLink(at: destination, withDestinationURL: bundled)
            return nil
        } catch {
            // `/usr/local/bin` is root-owned on a clean install, so the direct symlink cannot work
            // and asking for authorisation is the only way the button can do what it says.
            //
            // Doing that used to be refused here on the grounds that the app would not raise an
            // authorisation dialog "behind your back". The refusal was aimed at the wrong thing:
            // there is nothing behind anyone's back about a password prompt raised by pressing a
            // button labelled "Install the command line tool". What it produced instead was a dead
            // end — a command printed as unselectable text next to a button that had just failed.
            return await installWithAuthorization(bundled: bundled)
        }
    }

    /// Runs the link through the standard macOS authentication dialog — the same one `sudo` would
    /// put in Terminal, raised by the system rather than by us.
    ///
    /// Cancelling is a normal answer, not an error: it returns the command to run by hand, which is
    /// exactly what someone who would rather see what touches their `/usr/local` wants.
    private static func installWithAuthorization(bundled: URL) async -> String? {
        let shell = "mkdir -p /usr/local/bin && ln -sf '\(bundled.path)' '\(destination.path)'"
        // Escaped for AppleScript's own string literal, which is not the shell's.
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            // Off the main actor: the dialog is modal to the app and `waitUntilExit` would
            // otherwise block the very runloop that has to draw it.
            try await Task.detached {
                try process.run()
                process.waitUntilExit()
            }.value
        } catch {
            return declined(bundled: bundled)
        }
        guard process.terminationStatus == 0, case .installed = status() else {
            return declined(bundled: bundled)
        }
        return nil
    }

    private static func declined(bundled: URL) -> String {
        "Meetings was not allowed to write to /usr/local/bin. Run this in Terminal instead:\n"
            + manualCommand(bundled: bundled)
    }

    static func manualCommand(bundled: URL? = bundledCLI) -> String {
        let source = bundled?.path ?? "/Applications/Meetings.app/Contents/Helpers/meetings"
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(source)\" /usr/local/bin/meetings"
    }
}
