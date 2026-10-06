// Prints "<pid>\t<windowID>\t<width>x<height>" for every normal window a bundle id owns.
//
//   winlist com.yoelgal.meetings-film
//
// `video/shoot.sh` diffs two of these across a launch to find the window it just opened. Taking the
// process's largest window — what `scripts/shot.sh` does, correctly, for a single running copy — is
// not enough here: a launch that has not finished drawing has no window yet, the previous take's
// window may still be closing, and photographing either is how a take comes back wrong.
//
// Read-only. It never activates the app, and never touches a window.
import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: winlist <bundle-id>\n".utf8))
    exit(64)
}

let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1])
    .map(\.processIdentifier))
guard !pids.isEmpty else { exit(0) }

// `.optionAll` rather than `.optionOnScreenOnly`: a backgrounded or occluded window drops off the
// on-screen list but is still in the window list and still capturable. Layer 0 is a normal window
// rather than a panel or a popover, and the size floor drops the offscreen helpers every SwiftUI app
// owns a few of.
let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
for window in infos {
    guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
          (window[kCGWindowLayer as String] as? Int) == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let width = bounds["Width"], let height = bounds["Height"],
          width >= 200, height >= 200
    else { continue }
    print("\(pid)\t\(id)\t\(Int(width))x\(Int(height))")
}
