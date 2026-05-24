import AppKit
import SwiftUI

/// Forces the enclosing NSScrollView to use the slim overlay scroller style,
/// regardless of the user's macOS "Show scroll bars" preference.
///
/// SwiftUI's ScrollView on macOS inherits the system scroller style. When the
/// user has "Always" selected in System Settings → Appearance, the scrollbar
/// renders as a wide legacy scroller and eats into the content width. Applying
/// `.overlayScrollerStyle()` to the ScrollView's content pins it to the slim,
/// auto-hiding overlay style.
private struct OverlayScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // `enclosingScrollView` is only resolvable after the probe is attached
        // to the SwiftUI-managed NSScrollView's document view, so defer.
        DispatchQueue.main.async { [weak probe] in
            guard let scrollView = probe?.enclosingScrollView else { return }
            Self.configure(scrollView)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let scrollView = nsView?.enclosingScrollView else { return }
            Self.configure(scrollView)
        }
    }

    /// Apply the desired scroller appearance to the NSScrollView SwiftUI gave us.
    ///
    /// Decisions to make here:
    /// - Which `NSScroller.Style` to pin (`.overlay` vs `.legacy`)?
    /// - Should scrollers auto-hide when idle (`autohidesScrollers`)?
    /// - Do we want the vertical scroller present at all (`hasVerticalScroller`)?
    ///   What about the horizontal one?
    ///
    /// Note: setting `scrollerStyle` alone is not always enough — AppKit may
    /// have already cached the legacy scroller view. If the change does not
    /// take effect on first render, you may also need to nudge the existing
    /// `verticalScroller?.scrollerStyle` and/or call `tile()` to relayout.
    private static func configure(_ scrollView: NSScrollView) {
        guard scrollView.scrollerStyle != .overlay
            || scrollView.verticalScroller?.scrollerStyle != .overlay
            || !scrollView.autohidesScrollers
            || scrollView.hasHorizontalScroller else { return }

        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.tile()
    }
}

extension View {
    /// Forces the enclosing macOS NSScrollView to use the overlay (slim)
    /// scroller style. Apply to the *content* inside a SwiftUI `ScrollView`.
    func overlayScrollerStyle() -> some View {
        background(OverlayScrollerInstaller().frame(width: 0, height: 0))
    }
}
