import AppKit
import FlockCore
import SwiftUI

/// The close warning, drawn in the window rather than as a sheet: a sheet's
/// slide in and out is what made every warned close feel slow. A close made
/// with the mouse puts the card by the pointer; one made with a key centres it
/// over the tab's canvas. Return confirms and Esc cancels whatever holds the
/// keyboard.
struct CloseWarningCard: ViewModifier {
    let theme: Theme
    let viewModel: SessionViewModel

    @State private var input = CloseInputSource()
    @State private var pointer: CGPoint?
    @State private var cardSize: CGSize = .zero
    @State private var dontWarnAgain = false
    /// Outlives `pendingClose` by the exit fade. Input follows `pendingClose`
    /// alone, so an answered card takes no second answer while it fades.
    @State private var shown: CloseConfirmation?
    @State private var isIn = false
    @State private var selection = CloseCardItem.confirm

    private typealias M = ChromeMetrics.CloseCard

    func body(content: Content) -> some View {
        content
            .background(CloseInputMonitor(source: input, isActive: viewModel.pendingClose != nil, onKey: handle))
            .overlayPreferenceValue(TabAreaAnchor.self) { tabArea in
                if let shown {
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            if viewModel.pendingClose != nil {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { if let pending = viewModel.pendingClose { cancel(pending) } }
                            }
                            if let pointer {
                                let origin = origin(near: pointer, in: proxy.size)
                                card(shown)
                                    .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                                    .modifier(CardMotion(isIn: isIn, anchor: .topLeading))
                                    .offset(x: origin.x, y: origin.y)
                            } else {
                                let canvas = canvas(in: proxy.size, tabArea: tabArea.map { proxy[$0] })
                                card(shown)
                                    .modifier(CardMotion(isIn: isIn, anchor: .center))
                                    .frame(width: canvas.width, height: canvas.height)
                                    .offset(x: canvas.minX, y: canvas.minY)
                            }
                        }
                        .allowsHitTesting(viewModel.pendingClose != nil)
                    }
                }
            }
            .onChange(of: viewModel.pendingClose) { _, pending in
                if let pending {
                    pointer = input.pointer()
                    selection = .confirm
                    shown = pending
                    isIn = false
                    // A turn later, so the card first lays out at its starting
                    // scale and the entrance has somewhere to come from.
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: M.enterDuration)) { isIn = true }
                    }
                } else {
                    withAnimation(.easeIn(duration: M.exitDuration)) {
                        isIn = false
                    } completion: {
                        if viewModel.pendingClose == nil { shown = nil }
                    }
                }
            }
    }

    /// Kept inside the window, clear of the title bar. Until the card has been
    /// measured once it clamps as if it had no size.
    private func origin(near pointer: CGPoint, in bounds: CGSize) -> CGPoint {
        let top = ChromeMetrics.TitleBar.height + M.edgeMargin
        let x = pointer.x + M.pointerOffset, y = pointer.y + M.pointerOffset
        return CGPoint(
            x: min(max(x, M.edgeMargin), max(M.edgeMargin, bounds.width - cardSize.width - M.edgeMargin)),
            y: min(max(y, top), max(top, bounds.height - cardSize.height - M.edgeMargin))
        )
    }

    /// The tab strip shares the title bar's row, so the canvas starts below it.
    private func canvas(in bounds: CGSize, tabArea: CGRect?) -> CGRect {
        let area = tabArea ?? CGRect(origin: .zero, size: bounds)
        let top = max(area.minY, ChromeMetrics.TitleBar.height)
        return CGRect(x: area.minX, y: top, width: area.width, height: max(0, area.maxY - top))
    }

    /// The card takes the scheme opposite the window's, so a warning never
    /// sinks into the chrome around it.
    private var cardIsLight: Bool { !ChromeRoles.isLight(panelBg: theme.palette.panelBg) }

    private var colors: ChromeMetrics.CloseCard.Colors { cardIsLight ? .light : .dark }

    private func card(_ pending: CloseConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pending.title)
                .font(ChromeType.closeCardTitle)
                .foregroundStyle(Color(colors.title))
            VStack(alignment: .leading, spacing: M.pointGap) {
                ForEach(pending.points.isEmpty ? [pending.message] : pending.points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: M.markerGap) {
                        Circle()
                            .fill(Color(colors.body).opacity(M.markerOpacity))
                            .frame(width: M.markerSize, height: M.markerSize)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + M.markerBaselineLift }
                        Text(point)
                            .font(ChromeType.closeCardMessage)
                            .foregroundStyle(Color(colors.body))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, M.titleGap)
            if pending.warnsOfAgents {
                Toggle(isOn: $dontWarnAgain) {
                    Text("Don't warn me next time")
                        .font(ChromeType.closeCardMessage)
                        .foregroundStyle(Color(colors.body))
                }
                .toggleStyle(.checkbox)
                .modifier(SelectionRing(isSelected: selection == .dontWarn, color: theme.accent))
                .padding(.top, M.toggleTop)
                .accessibilityIdentifier("flock.close.dontWarn")
            }
            HStack(spacing: M.buttonGap) {
                Spacer(minLength: 0)
                Button("Cancel") { cancel(pending) }
                    .buttonStyle(CloseCardButtonStyle(fill: Color(colors.edge).opacity(M.quietFillOpacity), ink: Color(colors.title)))
                    .modifier(SelectionRing(isSelected: selection == .cancel, color: theme.accent))
                    .accessibilityIdentifier("flock.close.cancel")
                Button(pending.confirmButtonTitle) { confirm(pending) }
                    .buttonStyle(CloseCardButtonStyle(fill: theme.accent, ink: theme.chrome))
                    .modifier(SelectionRing(isSelected: selection == .confirm, color: theme.accent))
                    .accessibilityIdentifier("flock.close.confirm")
            }
            .padding(.top, M.buttonsTop)
        }
        .padding(M.padding)
        .frame(width: M.width, alignment: .leading)
        .environment(\.colorScheme, cardIsLight ? .light : .dark)
        // On the ground alone: a shadow over the whole card haloes its text.
        // A tight contact shadow under a wide soft one lifts the card off the
        // chrome instead of pressing it flat.
        .background {
            RoundedRectangle(cornerRadius: M.cornerRadius)
                .fill(Color(colors.ground))
                .shadow(color: .black.opacity(M.contactShadowOpacity), radius: M.contactShadowRadius, y: M.contactShadowY)
                .shadow(color: .black.opacity(M.liftShadowOpacity), radius: M.liftShadowRadius, y: M.liftShadowY)
        }
        .overlay(RoundedRectangle(cornerRadius: M.cornerRadius).strokeBorder(Color(colors.edge).opacity(colors.edgeOpacity), lineWidth: ChromeMetrics.ruleWidth))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.close.card")
    }

    /// Every key goes to the card while it is up, so none reaches a terminal.
    private func handle(_ event: NSEvent) {
        guard let pending = viewModel.pendingClose else { return }
        let items: [CloseCardItem] = pending.warnsOfAgents ? [.dontWarn, .cancel, .confirm] : [.cancel, .confirm]
        let backward = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 36, 76, 49:
            switch selection {
            case .dontWarn: dontWarnAgain.toggle()
            case .cancel: cancel(pending)
            case .confirm: confirm(pending)
            }
        case 53: cancel(pending)
        case 48: selection = Self.step(selection, in: items, by: backward ? -1 : 1)
        case 123, 126: selection = Self.step(selection, in: items, by: -1)
        case 124, 125: selection = Self.step(selection, in: items, by: 1)
        default: break
        }
    }

    /// Wraps at both ends, as Tab does through a dialog's controls.
    private static func step(_ item: CloseCardItem, in items: [CloseCardItem], by delta: Int) -> CloseCardItem {
        guard let index = items.firstIndex(of: item) else { return items.last ?? item }
        return items[(index + delta + items.count) % items.count]
    }

    private func confirm(_ pending: CloseConfirmation) { answer(pending, confirm: true) }

    private func cancel(_ pending: CloseConfirmation) { answer(pending, confirm: false) }

    private func answer(_ pending: CloseConfirmation, confirm: Bool) {
        let stopWarning = dontWarnAgain
        dontWarnAgain = false
        Task { await viewModel.answerClose(pending.subject, confirm: confirm, stopWarning: stopWarning) }
    }
}

/// Whether the latest input was a key or the mouse, and where the pointer is,
/// in the space of the view it backs.
@MainActor
final class CloseInputSource {
    fileprivate weak var view: NSView?
    fileprivate var lastWasPointer = false

    /// Nil unless the latest input was the mouse and the pointer is inside the view.
    func pointer() -> CGPoint? {
        guard lastWasPointer, let view, let window = view.window else { return nil }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return view.bounds.contains(point) ? point : nil
    }
}

private struct CloseInputMonitor: NSViewRepresentable {
    let source: CloseInputSource
    let isActive: Bool
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        source.view = view
        view.source = source
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        source.view = view
        view.source = source
        view.isActive = isActive
        view.onKey = onKey
    }

    final class MonitorView: NSView {
        weak var source: CloseInputSource?
        var isActive = false
        var onKey: (NSEvent) -> Void = { _ in }
        nonisolated(unsafe) private var monitors: [Any] = []

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []
            guard let window else { return }
            let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                self.source?.lastWasPointer = false
                guard self.isActive else { return event }
                self.onKey(event)
                return nil
            }
            let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.source?.lastWasPointer = true
                return event
            }
            monitors = [keys, mouse].compactMap { $0 }
        }
    }
}

/// The card's entrance and exit: a short fade with a slight grow from where it
/// sits, so it arrives without a sheet's long slide.
private struct CardMotion: ViewModifier {
    let isIn: Bool
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(isIn ? 1 : ChromeMetrics.CloseCard.enterScale, anchor: anchor)
            .opacity(isIn ? 1 : 0)
    }
}

/// Flock's own button rather than the system's: a bordered or prominent
/// button greys out in a window that is not key, and its system blue belongs
/// to no theme.
private struct CloseCardButtonStyle: ButtonStyle {
    let fill: Color
    let ink: Color

    private typealias M = ChromeMetrics.CloseCard

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ChromeType.closeCardButton)
            .foregroundStyle(ink)
            .padding(.horizontal, M.buttonHorizontalPadding)
            .frame(height: M.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: M.buttonCornerRadius)
                    .fill(fill)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .contentShape(Rectangle())
    }
}

private enum CloseCardItem {
    case dontWarn, cancel, confirm
}

/// The keyboard's place on the card, drawn the way macOS draws a focus ring:
/// an accent outline standing just off the control.
private struct SelectionRing: ViewModifier {
    let isSelected: Bool
    let color: Color

    private typealias M = ChromeMetrics.CloseCard

    func body(content: Content) -> some View {
        content.overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: M.buttonCornerRadius + M.ringOffset)
                    .strokeBorder(color.opacity(M.ringOpacity), lineWidth: M.ringWidth)
                    .padding(-M.ringOffset)
                    .allowsHitTesting(false)
            }
        }
    }
}
