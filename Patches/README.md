# Patches

Changes we would like in a dependency, kept here as patches rather than as a fork.

**Nothing in this directory is applied to the build.** The dependency is linked unmodified at the
version `Package.swift` pins. A patch here is a proposal to send upstream; until it lands, the app
works without it.

---

## `swift-markdown-engine-0.12.0-selection-rect.patch`

**Against** `nodes-app/swift-markdown-engine` at `0.12.0`.
**Applies with** `git apply -p1` from the library's repository root.

### What it adds

One public closure on `NativeTextViewWrapper`:

```swift
public var onSelectionRectChange: ((CGRect?, NSRange) -> Void)?
```

It fires after **every** selection change with the on-screen rect of the selection (or caret) and
the range it covers.

### Why

The engine already computes exactly this rect. `NSTextView.viewRect(forCharacterRange:using:)`
(`Sources/MarkdownEngine/TextView/Coordinator/NativeTextViewCoordinator.swift:461`) lifts a glyph
rect out of the text view's own space, through the container document view — which is where the
reading-column centring and the scroll-away header band live — and then subtracts the scroll offset.
That transform is the hard part, and it is right.

What it is not is reachable. It is `internal`, it needs the `internal` `LayoutBridge`, and the one
place the result is handed to an embedder — `onCaretRectChange`, via `textViewDidChangeSelection` —
is gated on the caret being inside an active `[[wiki-link]]` or `![[image embed]]`. An embedder that
wants to hang a selection toolbar or a slash-command menu over the text therefore has the rect
computed for it, correctly, and no way to read it.

The two workarounds both cost more than the patch:

1. **Re-derive the rect.** The embedder would have to reproduce the container-origin, reading-column
   and header transforms against a `textLayoutManager` it reached by introspection — a second copy
   of arithmetic the library already owns, which will drift the first time either offset changes.
2. **Go out to the screen and back.** Find the `NSTextView` by walking the view tree (the
   `NSViewType` is a public `NSScrollView`, so `documentView` is reachable), then take
   `firstRect(forCharacterRange:actualRange:)` and convert screen → window → embedder view. This is
   what this app does today and it is correct — AppKit's own view-tree conversion absorbs both
   offsets — but it depends on finding an `internal` view by walking, which is not an API contract.

### Where the call sits, and why there

The new call is inside the existing `if !shouldSkipSelectionRestyle` guard at the end of
`textViewDidChangeSelection`, beside `updateCodeBlockSelection`. That guard exists because
"`viewRect` is stale until `textDidChange`'s restyle runs; otherwise the overlay flashes to the old
Y before settling" — the library's own comment. A selection toolbar has exactly that problem, so it
wants exactly that guard: reporting the rect from the top of the method would hand embedders a rect
measured against the pre-edit layout, which is the class of bug this closure exists to prevent.

`nil` is passed when `viewRect` cannot measure — no layout yet — so an embedder can distinguish
"off screen" from "at the origin".

### Cost

Thirteen lines, ten of which are documentation. No behaviour changes when the closure is nil: the
`if let onSelectionRectChange` short-circuits before any work is done, so a document with no
embedder-supplied toolbar pays one optional test per selection change.
