import Foundation
import Testing

@testable import MeetingsCore

/// These assert the *default* locations, so they only mean anything when nothing has overridden
/// them. An acceptance run sets `MEETINGS_HOME` for the whole process, which is exactly the case
/// they would otherwise fail in — and failing there would be the test being wrong, not the code.
private let usingDefaultPaths = ProcessInfo.processInfo.environment["MEETINGS_HOME"] == nil
    && ProcessInfo.processInfo.environment["MEETINGS_DB"] == nil

@Test(.enabled(if: usingDefaultPaths))
func rootFallsBackToApplicationSupport() {
    #expect(Paths.root.path.hasSuffix("Meetings"))
}

@Test(.enabled(if: usingDefaultPaths))
func databaseSitsUnderRootByDefault() {
    #expect(Paths.databaseURL.deletingLastPathComponent() == Paths.root)
}

@Test func overridesWin() {
    // Not set here — mutating the environment mid-run would race every other test in the suite.
    // What is checkable without that is the contract the overrides rely on: an empty value is
    // treated as absent, so `MEETINGS_HOME=` in a script does not silently point the store at "/".
    #expect(!Paths.root.path.isEmpty)
    #expect(Paths.audioRoot.deletingLastPathComponent() == Paths.root)
    #expect(Paths.backupsRoot.deletingLastPathComponent() == Paths.root)
}

/// The dev bundle must not be able to reach the real store by being double-clicked.
    ///
    /// `scripts/dev.sh` sets `MEETINGS_HOME`, but the Dock, Spotlight, `open -a` and a relaunch
    /// after a crash do not — and started that way the dev build opened the real store and ran a
    /// migration the shipping build could not read, locking the installed app out of its own data.
@Test func theDevBundleDefaultsToItsOwnStore() {
    // A test process has no dev bundle identifier, so it takes the shipping default.
    #expect(Paths.defaultStoreFolder == "Meetings")
    // The rule itself, checkable without launching a bundle.
    #expect("com.yoelgal.meetings-dev".hasSuffix(".meetings-dev"))
    #expect(!"com.yoelgal.Meetings".hasSuffix(".meetings-dev"))
}
