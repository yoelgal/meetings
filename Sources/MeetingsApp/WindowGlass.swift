import AppKit
import SwiftUI

/// Main-window frost (toolbar title visible). Onboarding uses ``OpaqueGlass`` + hidden title
/// — same stack as OpenLookAway.
struct WindowGlass: NSViewRepresentable {
    var titleVisible: Bool = true

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async { Self.apply(probe.window, titleVisible: titleVisible) }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(view.window, titleVisible: titleVisible) }
    }

    static func apply(_ window: NSWindow?, titleVisible: Bool = true) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = titleVisible ? .visible : .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true

        if let content = window.contentView {
            for sub in content.subviews {
                let raw = sub.identifier?.rawValue ?? ""
                if raw.hasPrefix("meetings-window-glass") {
                    sub.removeFromSuperview()
                }
            }
            softSplitDividers(in: content)
        }
    }

    private static func softSplitDividers(in root: NSView) {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let split = view as? NSSplitView {
                split.dividerStyle = .thin
            }
            stack.append(contentsOf: view.subviews)
        }
    }
}

extension View {
    func windowGlass(titleVisible: Bool = true) -> some View {
        containerBackground(for: .window) {
            ZStack {
                Rectangle().fill(Material.regular.materialActiveAppearance(.active))
                Color.black.opacity(0.32)
            }
        }
        .background(WindowGlass(titleVisible: titleVisible))
    }
}

/// Detail column. Same frost as the window — no second glass layer.
struct GlassContentCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.clear)
    }
}

extension View {
    /// Light hairline on a split column's trailing edge.
    func columnTrailingHairline() -> some View {
        overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }
}

/// Applies ``windowGlass`` only when the main chrome is showing (not the wizard).
struct MainWindowGlass: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.windowGlass(titleVisible: true)
        } else {
            content
                .background(WindowGlass(titleVisible: false))
        }
    }
}
