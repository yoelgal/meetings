import AppKit
import MeetingsCore
import SwiftUI

/// The one window the slash menu and the selection toolbar are drawn in.
///
/// **Why a window at all.** Both surfaces used to be `.overlay`s on the engine's scroll view, placed
/// with alignment guides. The placement was right — traced from the running app, the menu computed
/// 1854 pt down a 2230 pt editor with the caret at 2159 — and the menu still drew inline with the
/// first heading. Seven fixes to the arithmetic all measured correctly in a harness and all landed
/// wrong on screen: a SwiftUI overlay inside scrolling content does not draw where it is told, and
/// no further guess about guides was going to change that.
///
/// So the surfaces are put where AppKit puts a menu: a borderless `.nonactivatingPanel`, a **child
/// window** of the editor's window, positioned in **screen coordinates**. Nothing can clip it, no
/// scroll view can move it, and SwiftUI's layout is not involved in where it lands — only in what it
/// draws.
///
/// It is the same mechanism ``NotesPanel`` runs on, for the same reason, and a child of that panel
/// when the editor is the one inside it.
@MainActor final class EditorSurfacePanel {
    /// **Never key.** The menu filters while you keep typing and the toolbar appears over a live
    /// selection; a window that took focus would end both. `canBecomeKey` is the only answer AppKit
    /// takes for certain — `becomesKeyOnlyIfNeeded` still lets a text field in the content claim it.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A click on a window that will never be key is a click AppKit would otherwise spend on
    /// activating it. Every row of the menu is a button, so it has to arrive at the view.
    private final class Content: NSHostingView<EditorSurfaceContent> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// What the last `show` asked for, kept so a re-layout of the content can be repositioned
    /// against the same caret without waiting for the next keystroke.
    private struct Request {
        let anchor: CGRect
        let visible: CGRect
        let prefer: MarkdownEditing.Side
        weak var probe: MarkdownEditorProbe?
    }

    private var panel: Panel?
    private var hosting: Content?
    private var request: Request?

    /// Puts `surface` over `anchor`, which is in the probe's own (flipped) coordinates.
    ///
    /// No window means no panel: the editor is mounted but not on screen — which is exactly the
    /// state the mount tests run in, and they must never put one there.
    func show(
        _ surface: MarkdownEditing.Surface, over anchor: CGRect, in visible: CGRect,
        from probe: MarkdownEditorProbe, bridge: MarkdownEditorBridge
    ) {
        guard let window = probe.window else { return hide() }
        request = Request(anchor: anchor, visible: visible, prefer: surface.prefer, probe: probe)
        let panel = self.panel ?? make(for: bridge)
        // Framed **before** it is ordered in, and not ordered in at all until it has a frame: a
        // window shown at its default 1 × 1 is a speck in the corner of the display for as long as
        // it takes SwiftUI to report a size. The content calls back the moment it has one.
        guard position() else { return }
        // Its own hosting view has no environment from the app, and the window level and the
        // capture policy belong to whoever it is hanging off: a menu opened in the notes panel is
        // hidden from a screen share exactly as the panel is, which is a privacy feature and not a
        // detail. Re-read every time, because both are settings the user can change while it is up.
        panel.appearance = window.appearance
        panel.level = window.level
        panel.sharingType = window.sharingType
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            // A child window travels with its parent, closes with it, and stays ordered above it —
            // and `addChildWindow` orders it in without making it key or activating the app.
            window.addChildWindow(panel, ordered: .above)
        } else if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    /// Off screen, and out of the parent's child list — a child window left attached is one that
    /// comes back with the parent the next time it is ordered front.
    func hide() {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Torn down with the editor. The bridge's `deinit` calls this, so an editor that is unmounted
    /// while its menu is open does not leave a window on screen belonging to nothing.
    func close() {
        hide()
        panel?.close()
        panel = nil
        hosting = nil
        request = nil
    }

    private func make(for bridge: MarkdownEditorBridge) -> Panel {
        let hosting = Content(rootView: EditorSurfaceContent(bridge: bridge) { [weak self] in
            // Out of SwiftUI's layout pass: this arrives *during* one, and `position` measures the
            // same hosting view it is being reported by.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.position() }
            }
        })
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.contentView = hosting
        // The surfaces draw their own material and border, so the window is only a place to put
        // them — and the shadow is the window's, because a SwiftUI shadow inside a frame this tight
        // is clipped by it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// The conversion, in full: the surface's size from SwiftUI, the placement from
    /// ``MarkdownEditing/floating(over:size:in:prefer:gap:)`` in the probe's flipped space, the
    /// probe's own rect through `convert(_:to: nil)` into window space and `convertToScreen` onto
    /// the display — and the flip between the two, which is the one piece of arithmetic here and is
    /// tested in `EditorSurfaceGeometryTests`.
    @discardableResult private func position() -> Bool {
        guard let panel, let hosting, let request,
              let probe = request.probe, let window = probe.window
        else { return false }
        // Measured on macOS 26: `layoutSubtreeIfNeeded` flushes the update an `@Observable` change
        // scheduled, so `fittingSize` is the size of the content *after* the keystroke that filtered
        // the menu — nine rows to one comes back as 30 pt on the same turn, not 270. Without that,
        // every filtered keystroke would place the panel at the previous size for a frame.
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        // A surface that has not been laid out has no size and no place to be. Waiting is right:
        // the content reports its size the moment it has one, and that call comes back here.
        guard size.width > 0, size.height > 0 else { return false }
        let placement = MarkdownEditing.floating(
            over: request.anchor, size: size, in: request.visible, prefer: request.prefer
        )
        let probeOnScreen = window.convertToScreen(probe.convert(probe.bounds, to: nil))
        panel.setFrame(
            EditorSurface.frame(placement, size: size, probe: probeOnScreen), display: true
        )
        // The shadow is the window's, and a window that has moved or changed size keeps the old one
        // until it is told otherwise.
        panel.invalidateShadow()
        return true
    }
}

/// The arithmetic between the probe's space and the screen's, kept out of the class so it can be
/// checked without a window — which is the whole reason this rewrite exists.
enum EditorSurface {
    /// Where the surface goes on the display.
    ///
    /// `placement` is in ``MarkdownEditorProbe`` coordinates, which are **flipped**: y counts down
    /// from the probe's top edge. A window frame is in screen coordinates, where y counts up from
    /// the bottom of the main display — so the top edge of the surface is `probe.maxY - placement.y`
    /// and its origin is one height below that.
    static func frame(
        _ placement: MarkdownEditing.Placement, size: CGSize, probe: CGRect
    ) -> CGRect {
        CGRect(
            x: probe.minX + placement.x,
            y: probe.maxY - placement.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}

/// What the panel draws: the menu while there is a query, the toolbar otherwise.
///
/// It reads the bridge directly, so filtering the menu, arrowing down it and the engine's own
/// "is the selection bold" all redraw without anybody being told to. Only the *geometry* is pushed:
/// `measured` fires after each layout, and the panel re-places itself against the caret with the
/// size the content has just taken.
struct EditorSurfaceContent: View {
    let bridge: MarkdownEditorBridge
    let measured: () -> Void

    var body: some View {
        surface
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in measured() }
    }

    @ViewBuilder private var surface: some View {
        if let query = bridge.openQuery {
            SlashMenu(matches: query.matches, highlighted: bridge.highlightedRow) { command in
                bridge.choose(command)
            }
        } else {
            SelectionToolbar(isBold: bridge.isBold, isItalic: bridge.isItalic) { action in
                bridge.run(action)
            }
        }
    }
}
