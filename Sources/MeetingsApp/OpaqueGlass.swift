import AppKit
import SwiftUI

struct OpaqueGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
    }
}

extension NSWindow {
    func installGlassHost<Content: View>(
        _ root: Content,
        material: NSVisualEffectView.Material = .underWindowBackground,
        cornerRadius: CGFloat = 0
    ) {
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        let glass = NSVisualEffectView()
        glass.material = material
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.isEmphasized = true
        glass.autoresizingMask = [.width, .height]
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)

        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.isOpaque = false
        clip.layer?.backgroundColor = NSColor.clear.cgColor
        if cornerRadius > 0 {
            clip.layer?.cornerRadius = cornerRadius
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            glass.wantsLayer = true
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
        }
        clip.addSubview(glass)
        contentView = clip
        glass.frame = clip.bounds
        host.frame = glass.bounds
        isOpaque = false
        backgroundColor = .clear
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hasShadow = true
        invalidateShadow()
    }
}
