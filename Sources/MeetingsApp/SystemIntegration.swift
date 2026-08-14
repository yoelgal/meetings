import AVFoundation
import AppKit
import CoreGraphics
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
}

/// Whether this build was signed ad hoc, which decides whether the permissions you grant survive
/// the next update.
///
/// macOS keys a TCC grant to the app's code signature. An ad-hoc signature *is* a hash of the app's
/// own code, so the next build is a different app to the permission system and every grant is asked
/// for again. Nothing in the app said so: you granted the microphone, updated a week later, were
/// asked again, and the only explanation was in a README section about code signing.
///
/// Read once. A running process cannot change its own signature.
enum CodeSignature {
    static let isAdHoc: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess, let dictionary = information as? [String: Any] else { return false }
        // An ad-hoc signature carries no certificate chain. Any named identity, self-signed or a
        // real Developer ID, puts at least one certificate here.
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [Any]
        return certificates?.isEmpty ?? true
    }()

    // False when the check itself fails, so an unexpected answer from the Security framework leaves
    // the app quiet rather than telling someone their perfectly-signed build is about to lose their
    // permissions.
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
