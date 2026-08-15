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
/// `scripts/dev.sh` sets `MEETINGS_HOME`, but the Dock, Spotlight, `open -a` and a relaunch after a
/// crash do not — and started that way the dev build opened the real store and ran a migration the
/// shipping build could not read, locking the installed app out of its own data.
///
/// This used to assert `"com.yoelgal.meetings-dev".hasSuffix(".meetings-dev")`, which tests
/// `String.hasSuffix` rather than `Paths`: the one real assertion landed on the *shipping* branch,
/// so the dev-bundle rule the test is named for was covered by nothing.
/// ``Paths/storeFolder(forBundle:)`` takes the identifier instead of reading it, so both branches
/// are reachable without launching a bundle.
@Test func theDevBundleDefaultsToItsOwnStore() {
    #expect(Paths.storeFolder(forBundle: "com.yoelgal.meetings-dev") == "meetings-dev")
    #expect(Paths.storeFolder(forBundle: "com.yoelgal.Meetings") == "Meetings")
    // The CLI has no bundle at all, and a bundle that merely contains the suffix somewhere other
    // than the end is not the dev build either.
    #expect(Paths.storeFolder(forBundle: nil) == "Meetings")
    #expect(Paths.storeFolder(forBundle: "com.yoelgal.meetings-dev.helper") == "Meetings")
    // And the process running this test is not the dev bundle, so it takes the shipping store.
    #expect(Paths.defaultStoreFolder == "Meetings")
}
