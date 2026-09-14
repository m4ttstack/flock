import CoreGraphics

/// One pane-body drag event as the AppKit pane body reports it.
///
/// `point` is in the body's own space with a TOP-LEFT origin, which is NOT
/// AppKit's own: the body flips once on the way out, and the SwiftUI wrapper
/// then adds the body's origin in the drag space. Those two steps are the
/// whole conversion between AppKit's coordinates and the drag layer's.
enum PaneBodyDragEvent: Equatable {
    case began(CGPoint)
    case moved(CGPoint)
    case ended(CGPoint)
}
