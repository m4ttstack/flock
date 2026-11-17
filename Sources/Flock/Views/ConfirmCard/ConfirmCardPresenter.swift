import AppKit
import FlockCore
import SwiftUI

/// What a confirm card says. `message` is attributed so a prompt can bold the
/// figure it turns on without every caller's text being read as markdown.
struct ConfirmCardContent: Equatable {
    var action: String
    /// Shown apart from `action`, in a chip of its own.
    var name: String?
    var message: AttributedString
    /// A checkbox's label, such as "Don't warn me next time".
    var suppression: String?
    /// Nil for a card with one button, which only acknowledges.
    var cancelTitle: String? = "Cancel"
    var confirmTitle: String
    /// Prefix for the card's accessibility identifiers: `.card`, `.confirm`,
    /// `.cancel` and `.suppress`.
    var identifier: String
}

/// How a card was raised, read once as it shows.
enum ConfirmOrigin: Equatable {
    case keyboard
    /// `point` is nil when the pointer has left the window.
    case pointer(CGPoint?, pressOnTitleBar: Bool)
}

struct ConfirmAnswer {
    let confirmed: Bool
    /// The checkbox's state, which counts whichever way the card was answered,
    /// as a system alert's suppression box does.
    let suppressed: Bool
}

/// A confirm drawn in the window rather than as a sheet, whose slide in and
/// out makes every prompt feel slow. It shows while `item` is set: hung from
/// `anchor`'s frame when that gives one, centred on the pointer when the
/// mouse raised it, and otherwise resting over the tab's canvas. Every key
/// goes to the card while it is up: Tab and the arrows move its focus ring,
/// Return or Space act on it, Esc cancels, and so does a click outside.
struct ConfirmCardPresenter<Item: Equatable>: ViewModifier {
    let theme: Theme
    let item: Item?
    let content: (Item) -> ConfirmCardContent
    /// A frame in the overlay's own space for the card to hang from.
    var anchor: (Item, ConfirmOrigin, GeometryProxy) -> CGRect? = { _, _, _ in nil }
    /// Called once per showing. The card goes when `item` clears.
    let answer: (Item, ConfirmAnswer) -> Void

    @State private var input = ConfirmInputSource()
    @State private var origin = ConfirmOrigin.keyboard
    @State private var cardSize: CGSize = .zero
    @State private var suppressed = false
    /// Outlives `item` by the exit fade. Input follows `item` alone, so an
    /// answered card takes no second answer while it fades.
    @State private var shown: Item?
    @State private var isIn = false
    @State private var selection = ConfirmCardItem.confirm
    /// An answer can clear `item` a turn late; this keeps it to one.
    @State private var isAnswered = false

    private typealias M = ChromeMetrics.ConfirmCard

    func body(content: Content) -> some View {
        content
            .background(ConfirmInputMonitor(source: input, isActive: item != nil && !isAnswered, onKey: handle))
            .overlayPreferenceValue(TabAreaAnchor.self) { tabArea in
                if let shown {
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            if item != nil && !isAnswered {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { respond(confirmed: false) }
                            }
                            placed(shown, in: proxy, tabArea: tabArea.map { proxy[$0] })
                        }
                        .allowsHitTesting(item != nil && !isAnswered)
                    }
                }
            }
            .onChange(of: item) { _, item in
                if let item {
                    origin = input.origin()
                    selection = .confirm
                    suppressed = false
                    isAnswered = false
                    shown = item
                    isIn = false
                    // A turn later, so the card first lays out at its starting
                    // scale and the entrance has somewhere to come from.
                    Task { @MainActor in
                        withAnimation(.snappy(duration: M.enterDuration)) { isIn = true }
                    }
                } else {
                    withAnimation(.easeIn(duration: M.exitDuration)) {
                        isIn = false
                    } completion: {
                        if self.item == nil { shown = nil }
                    }
                }
            }
    }

    @ViewBuilder
    private func placed(_ shown: Item, in proxy: GeometryProxy, tabArea: CGRect?) -> some View {
        let text = content(shown)
        if let frame = anchor(shown, origin, proxy) {
            let hung = hang(below: frame, in: proxy.size)
            card(text, arrowX: hung.arrowX)
                .modifier(CardMotion(isIn: isIn, anchor: UnitPoint(x: hung.arrowX / M.width, y: 0)))
                .offset(x: hung.origin.x, y: hung.origin.y)
        } else if case .pointer(let point?, _) = origin {
            card(text)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                .modifier(CardMotion(isIn: isIn, anchor: .center))
                .position(centre(on: point, in: proxy.size))
        } else {
            let canvas = canvas(in: proxy.size, tabArea: tabArea)
            card(text)
                .modifier(CardMotion(isIn: isIn, anchor: .center))
                .alignmentGuide(.confirmCardRest) { $0[VerticalAlignment.center] }
                .frame(width: canvas.width, height: canvas.height, alignment: Alignment(horizontal: .center, vertical: .confirmCardRest))
                .offset(x: canvas.minX, y: canvas.minY)
        }
    }

    /// On the pointer, kept inside the window and clear of the title bar,
    /// however near an edge the pointer was. The width is fixed; until the
    /// card has been measured its height is estimated, so even its first
    /// frame stays inside.
    private func centre(on pointer: CGPoint, in bounds: CGSize) -> CGPoint {
        let height = cardSize.height > 0 ? cardSize.height : M.estimatedHeight
        let half = CGSize(width: M.width / 2, height: height / 2)
        let top = ChromeMetrics.TitleBar.height + M.edgeMargin
        return CGPoint(
            x: min(max(pointer.x, M.edgeMargin + half.width), max(M.edgeMargin + half.width, bounds.width - half.width - M.edgeMargin)),
            y: min(max(pointer.y, top + half.height), max(top + half.height, bounds.height - half.height - M.edgeMargin))
        )
    }

    /// Centred under the frame where the window allows, its arrow on the
    /// frame's middle wherever the card itself had to shift.
    private func hang(below frame: CGRect, in bounds: CGSize) -> (origin: CGPoint, arrowX: CGFloat) {
        let x = min(max(frame.midX - M.width / 2, M.edgeMargin), max(M.edgeMargin, bounds.width - M.width - M.edgeMargin))
        let reach = M.cornerRadius + M.arrowWidth / 2
        let arrowX = min(max(frame.midX - x, reach), M.width - reach)
        return (CGPoint(x: x, y: frame.maxY + M.tabGap), arrowX)
    }

    /// The tab strip shares the title bar's row, so the canvas starts below it.
    private func canvas(in bounds: CGSize, tabArea: CGRect?) -> CGRect {
        let area = tabArea ?? CGRect(origin: .zero, size: bounds)
        let top = max(area.minY, ChromeMetrics.TitleBar.height)
        return CGRect(x: area.minX, y: top, width: area.width, height: max(0, area.maxY - top))
    }

    /// The card takes the scheme opposite the window's, so a prompt never
    /// sinks into the chrome around it.
    private var cardIsLight: Bool { !ChromeRoles.isLight(panelBg: theme.palette.panelBg) }

    private var colors: ChromeMetrics.ConfirmCard.Colors { cardIsLight ? .light : .dark }

    private func card(_ text: ConfirmCardContent, arrowX: CGFloat? = nil) -> some View {
        let shape = CalloutShape(cornerRadius: M.cornerRadius, arrowX: arrowX, arrowWidth: M.arrowWidth, arrowHeight: M.arrowHeight)
        return VStack(alignment: .leading, spacing: 0) {
            Text(text.action)
                .font(ChromeType.confirmCardTitle)
                .foregroundStyle(Color(colors.title))
            if let name = text.name {
                Text(name)
                    .font(ChromeType.confirmCardName)
                    .foregroundStyle(Color(colors.title))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, M.nameChipHorizontalPadding)
                    .padding(.vertical, M.nameChipVerticalPadding)
                    .background(Color(colors.edge).opacity(M.nameChipFillOpacity), in: RoundedRectangle(cornerRadius: M.buttonCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: M.buttonCornerRadius)
                            .strokeBorder(Color(colors.edge).opacity(M.nameChipEdgeOpacity), lineWidth: ChromeMetrics.ruleWidth)
                    )
                    .padding(.top, M.nameChipTop)
            }
            Text(text.message)
                .font(ChromeType.confirmCardMessage)
                .foregroundStyle(Color(colors.body))
                .lineSpacing(M.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.titleGap)
            if let suppression = text.suppression {
                Toggle(isOn: $suppressed) {
                    Text(suppression)
                        .font(ChromeType.confirmCardMessage)
                        .foregroundStyle(Color(colors.body))
                }
                .toggleStyle(.checkbox)
                .modifier(SelectionRing(isSelected: selection == .dontWarn, color: theme.accent, inset: M.toggleRingInset))
                .padding(.top, M.toggleTop)
                .accessibilityIdentifier("\(text.identifier).suppress")
            }
            HStack(spacing: M.buttonGap) {
                Spacer(minLength: 0)
                if let cancelTitle = text.cancelTitle {
                    Button(cancelTitle) { respond(confirmed: false) }
                        .buttonStyle(ConfirmCardButtonStyle(
                            fill: Color(colors.edge).opacity(M.quietFillOpacity),
                            pressedFill: Color(colors.edge).opacity(M.quietPressedFillOpacity),
                            ink: Color(colors.title)
                        ))
                        .modifier(SelectionRing(isSelected: selection == .cancel, color: theme.accent))
                        .accessibilityIdentifier("\(text.identifier).cancel")
                }
                Button(text.confirmTitle) { respond(confirmed: true) }
                    .buttonStyle(ConfirmCardButtonStyle(fill: theme.accent, pressedFill: nil, ink: theme.chrome))
                    .modifier(SelectionRing(isSelected: selection == .confirm, color: theme.accent))
                    .accessibilityIdentifier("\(text.identifier).confirm")
            }
            .padding(.top, M.buttonsTop)
        }
        .padding(M.padding)
        .padding(.top, arrowX == nil ? 0 : M.arrowHeight)
        .frame(width: M.width, alignment: .leading)
        .environment(\.colorScheme, cardIsLight ? .light : .dark)
        // On the ground alone: a shadow over the whole card haloes its text.
        // A tight contact shadow under a wide soft one lifts the card off the
        // chrome instead of pressing it flat.
        .background {
            shape
                .fill(Color(colors.ground))
                .shadow(color: .black.opacity(M.contactShadowOpacity), radius: M.contactShadowRadius, y: M.contactShadowY)
                .shadow(color: .black.opacity(M.liftShadowOpacity), radius: M.liftShadowRadius, y: M.liftShadowY)
        }
        .overlay(shape.strokeBorder(Color(colors.edge).opacity(colors.edgeOpacity), lineWidth: ChromeMetrics.ruleWidth))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(text.identifier).card")
    }

    private func handle(_ event: NSEvent) {
        guard let item else { return }
        let text = content(item)
        let items = (text.suppression == nil ? [] : [ConfirmCardItem.dontWarn])
            + (text.cancelTitle == nil ? [] : [.cancel]) + [.confirm]
        let backward = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 36, 76, 49:
            switch selection {
            case .dontWarn: suppressed.toggle()
            case .cancel: respond(confirmed: false)
            case .confirm: respond(confirmed: true)
            }
        case 53: respond(confirmed: false)
        case 48: selection = Self.step(selection, in: items, by: backward ? -1 : 1)
        case 123, 126: selection = Self.step(selection, in: items, by: -1)
        case 124, 125: selection = Self.step(selection, in: items, by: 1)
        default: break
        }
    }

    /// Wraps at both ends, as Tab does through a dialog's controls.
    private static func step(_ item: ConfirmCardItem, in items: [ConfirmCardItem], by delta: Int) -> ConfirmCardItem {
        guard let index = items.firstIndex(of: item) else { return items.last ?? item }
        return items[(index + delta + items.count) % items.count]
    }

    private func respond(confirmed: Bool) {
        guard let item, !isAnswered else { return }
        isAnswered = true
        let suppressedNow = suppressed
        suppressed = false
        answer(item, ConfirmAnswer(confirmed: confirmed, suppressed: suppressedNow))
    }
}
