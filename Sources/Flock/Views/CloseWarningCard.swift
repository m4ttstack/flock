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

    private typealias M = ChromeMetrics.CloseCard

    func body(content: Content) -> some View {
        content
            .background(CloseInputMonitor(source: input, isActive: viewModel.pendingClose != nil, onKey: handle))
            .overlayPreferenceValue(TabAreaAnchor.self) { tabArea in
                if let pending = viewModel.pendingClose {
                    GeometryReader { proxy in
                        let origin = origin(in: proxy.size, tabArea: tabArea.map { proxy[$0] })
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { cancel(pending) }
                            card(pending)
                                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                                .opacity(cardSize == .zero ? 0 : 1)
                                .offset(x: origin.x, y: origin.y)
                        }
                    }
                }
            }
            .onChange(of: viewModel.pendingClose?.id) { _, id in
                guard id != nil else { return }
                cardSize = .zero
                pointer = input.pointer()
            }
    }

    private func origin(in bounds: CGSize, tabArea: CGRect?) -> CGPoint {
        let top = ChromeMetrics.TitleBar.height
        if let pointer {
            let x = pointer.x + M.pointerOffset, y = pointer.y + M.pointerOffset
            return CGPoint(
                x: min(max(x, M.edgeMargin), max(M.edgeMargin, bounds.width - cardSize.width - M.edgeMargin)),
                y: min(max(y, top + M.edgeMargin), max(top + M.edgeMargin, bounds.height - cardSize.height - M.edgeMargin))
            )
        }
        // The tab strip shares the title bar's row, so the canvas starts below it.
        let area = (tabArea ?? CGRect(origin: .zero, size: bounds))
        let canvas = CGRect(x: area.minX, y: max(area.minY, top), width: area.width, height: area.maxY - max(area.minY, top))
        return CGPoint(x: canvas.midX - cardSize.width / 2, y: canvas.midY - cardSize.height / 2)
    }

    private func card(_ pending: CloseConfirmation) -> some View {
        VStack(alignment: .leading, spacing: M.gap) {
            Text(pending.title)
                .font(ChromeType.closeCardTitle)
                .foregroundStyle(theme.textStrong)
            Text(pending.message)
                .font(ChromeType.closeCardMessage)
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            if pending.warnsOfAgents {
                Toggle(isOn: $dontWarnAgain) {
                    Text("Don't warn me next time")
                        .font(ChromeType.closeCardMessage)
                        .foregroundStyle(theme.textDim)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("flock.close.dontWarn")
            }
            HStack(spacing: M.buttonGap) {
                Spacer(minLength: 0)
                Button("Cancel") { cancel(pending) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("flock.close.cancel")
                Button(pending.confirmButtonTitle) { confirm(pending) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("flock.close.confirm")
            }
            .padding(.top, M.buttonsTop)
        }
        .padding(M.padding)
        .frame(width: M.width, alignment: .leading)
        .background(theme.chrome, in: RoundedRectangle(cornerRadius: M.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: M.cornerRadius).strokeBorder(theme.rule, lineWidth: ChromeMetrics.ruleWidth))
        .shadow(color: .black.opacity(ChromeMetrics.Modal.shadowOpacity), radius: ChromeMetrics.Modal.shadowRadius, y: ChromeMetrics.Modal.shadowY)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flock.close.card")
    }

    /// Every key goes to the card while it is up, so none reaches a terminal.
    private func handle(_ event: NSEvent) {
        guard let pending = viewModel.pendingClose else { return }
        switch event.keyCode {
        case 36, 76: confirm(pending)
        case 53: cancel(pending)
        default: break
        }
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
