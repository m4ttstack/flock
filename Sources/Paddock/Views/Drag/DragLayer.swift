import PaddockCore
import SwiftUI

/// Everything a drag draws above the window: the insertion bar, the outline
/// over a whole-item target, the landing flash, and the ghost itself. Every
/// rect arrives already in the drag space, so this view does no geometry of
/// its own and never takes a hit.
struct DragLayer: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(DragCoordinator.self) private var drag

    private var theme: Theme { themeStore.active }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let mark = drag.insertionMark {
                InsertionBar(theme: theme, mark: mark)
                    .transition(.opacity)
            }
            if let highlight = drag.targetHighlight {
                targetOutline(highlight)
                    .transition(.opacity)
            }
            if let flash = drag.landingFlash {
                LandingFlash(theme: theme, rect: flash.rect)
                    .id(flash.id)
            }
            if let ghost = drag.ghost, let topLeft = drag.ghostTopLeft {
                GhostOverlay(theme: theme, ghost: ghost, settling: drag.isSettling)
                    .offset(x: topLeft.x, y: topLeft.y)
                    // The settle spring is the ONLY animation on the ghost's
                    // position: while the drag is live it tracks the cursor
                    // frame for frame, and an animation there would lag it.
                    .animation(drag.isSettling ? .spring(duration: DragVisuals.settleDuration, bounce: DragVisuals.settleBounce) : nil, value: topLeft)
                    .opacity(drag.isSettling ? 0 : 1)
                    .animation(.easeIn(duration: DragVisuals.settleDuration), value: drag.isSettling)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: drag.insertionMark)
        .animation(.easeOut(duration: DragVisuals.previewCrossfadeDuration), value: drag.targetHighlight)
    }

    private func targetOutline(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.accent.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.accent, lineWidth: 2))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// The committed drop's landing zone, lit and then faded over
/// `DragVisuals.landingFlashDuration`. Identity is the flash's own id, so a
/// second drop in the same place restarts it rather than inheriting a fade
/// already in progress.
private struct LandingFlash: View {
    let theme: Theme
    let rect: CGRect

    @State private var faded = false

    var body: some View {
        // A wash, never a stroke: a pane drop lands exactly on a pane box,
        // so a stroked flash sits a couple of points inside the border the
        // pane already draws and doubles it for the whole fade.
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.accent.opacity(0.35))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .opacity(faded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: DragVisuals.landingFlashDuration)) { faded = true }
            }
    }
}
