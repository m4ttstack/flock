import AppKit
import Carbon.HIToolbox
import FlockCore
import SwiftUI

/// One of the four rows the FEATURES band lists, each carrying its own
/// shortcut and glyph. `chevron.left`/`xmark`, the two icons every sub-view's
/// own header carries, are not here: nothing in this enum routes to them.
enum ChatPopoverFeature: CaseIterable, Identifiable {
    case broadcast
    case peek
    case quickSend
    case openViewer

    var id: Self { self }

    var title: String {
        switch self {
        case .broadcast: "Broadcast to panes"
        case .peek: "Chat peek"
        case .quickSend: "Quick send"
        case .openViewer: "Open viewer"
        }
    }

    var shortcut: String {
        switch self {
        case .broadcast: "⌘⇧B"
        case .peek: "⌘⇧P"
        case .quickSend: "⌘⇧S"
        case .openViewer: "⌘⇧V"
        }
    }

    var symbolName: String {
        switch self {
        case .broadcast: "dot.radiowaves.left.and.right"
        case .peek: "person.2.fill"
        case .quickSend: "paperplane.fill"
        case .openViewer: "arrow.up.forward.square"
        }
    }
}

/// The launcher a pane's chat button opens: status, the four features, and
/// this pane's sign buttons -- rebuilt natively from `measurements.md`
/// ("Popover, both states"), never from the PNGs. Selecting Broadcast, Peek
/// or Quick send swaps this same content for a back-chevron placeholder; each
/// feature's real body is a later view hung off `ChatPopoverFeature` here.
/// Open viewer is not a route: it closes the popover and opens the URL, the
/// same as its header icon.
struct ChatPopover: View {
    let theme: Theme
    /// What the trailing chip in the status block names -- the pane this
    /// popover acts on, not anything `status` carries: `ChatStatus.pane` is
    /// `nil` while signed out, but the popover always knows its own pane.
    let paneName: String
    let status: ChatStatus?
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onOpenViewer: () -> Void

    @Binding private var isPresented: Bool
    @State private var route: Route = .status
    @State private var hoveredFeature: ChatPopoverFeature?

    private enum Route: Equatable {
        case status
        case feature(ChatPopoverFeature)
    }

    /// `previewHoveredFeature` exists only so a render test can sample the
    /// hovered/selected row's exact fill and icon colour without simulating a
    /// real pointer -- production call sites never pass it, and hovering
    /// updates the same `hoveredFeature` state afterward regardless.
    init(
        theme: Theme, paneName: String, status: ChatStatus?, isPresented: Binding<Bool>,
        onSignIn: @escaping () -> Void, onSignOut: @escaping () -> Void, onOpenViewer: @escaping () -> Void,
        previewHoveredFeature: ChatPopoverFeature? = nil
    ) {
        self.theme = theme
        self.paneName = paneName
        self.status = status
        self._isPresented = isPresented
        self.onSignIn = onSignIn
        self.onSignOut = onSignOut
        self.onOpenViewer = onOpenViewer
        self._hoveredFeature = State(initialValue: previewHoveredFeature)
    }

    var body: some View {
        Group {
            switch route {
            case .status: statusRoute
            case let .feature(feature): featurePlaceholder(feature)
            }
        }
        .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius).fill(Color(theme.palette.panelBg)))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius)
                .strokeBorder(Color(theme.palette.surface1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius))
        .background(ChatPopoverEscMonitor(isPresented: $isPresented))
    }

    private var hasRooms: Bool { status?.signedIn == true }

    // MARK: - Status route

    var statusRoute: some View {
        VStack(spacing: 0) {
            header
            statusBlock
            sectionLabel("FEATURES")
            featuresBlock
            sectionLabel("THIS PANE")
            signButtonsBlock
        }
        .frame(width: ChromeMetrics.ChatPopover.width)
    }

    var header: some View {
        HStack(spacing: 0) {
            Text("Chat")
                .font(ChromeType.chatPopoverTitle)
                .foregroundStyle(theme.text)
            Spacer(minLength: 0)
            Button(action: openViewer) {
                Image(systemName: "arrow.up.forward.square")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(theme.overlay0)
                    .frame(
                        width: ChromeMetrics.ChatPopover.Header.iconSize.width,
                        height: ChromeMetrics.ChatPopover.Header.iconSize.height
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ChromeMetrics.ChatPopover.Header.horizontalPadding)
        .frame(width: ChromeMetrics.ChatPopover.width, height: ChromeMetrics.ChatPopover.Header.height)
        .overlay(alignment: .bottom) { bandRule }
    }

    var statusBlock: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.ChatPopover.Status.gap) {
            HStack(spacing: ChromeMetrics.ChatPopover.Status.gap) {
                Circle()
                    .fill(status?.signedIn == true ? theme.green : theme.overlay0)
                    .frame(width: ChromeMetrics.ChatPopover.Status.dotSize, height: ChromeMetrics.ChatPopover.Status.dotSize)
                if let handle = status?.handle {
                    Text(handle)
                        .font(ChromeType.chatPopoverHandle)
                        .foregroundStyle(theme.text)
                }
                // rt's own vocabulary, never re-worded; empty until a status
                // has actually loaded for this pane.
                Text(status?.state ?? "")
                    .font(ChromeType.chatPopoverStateWord)
                    .foregroundStyle(theme.subtext0)
                Spacer(minLength: 0)
                paneChip
            }
            if hasRooms {
                HStack(spacing: ChromeMetrics.ChatPopover.Status.roomChipGap) {
                    ForEach(status?.rooms ?? [], id: \.self) { room in
                        roomChip(room)
                    }
                }
            }
        }
        .padding(.top, ChromeMetrics.ChatPopover.Status.topPadding)
        .padding(.trailing, ChromeMetrics.ChatPopover.Status.trailingPadding)
        .padding(.bottom, ChromeMetrics.ChatPopover.Status.bottomPadding)
        .padding(.leading, ChromeMetrics.ChatPopover.Status.leadingPadding)
        .frame(
            width: ChromeMetrics.ChatPopover.width,
            height: hasRooms ? ChromeMetrics.ChatPopover.Status.heightSignedIn : ChromeMetrics.ChatPopover.Status.heightSignedOut,
            alignment: .top
        )
        .overlay(alignment: .bottom) { bandRule }
    }

    /// The header and the status band are the only bands the popover rules
    /// off: a 1pt line in `surface0`, never the outer stroke's own colour.
    private var bandRule: some View {
        Rectangle().fill(Color(theme.palette.surface0)).frame(height: 1)
    }

    private var paneChip: some View {
        HStack(spacing: ChromeMetrics.ChatPopover.Status.paneChipGap) {
            Image(systemName: "terminal")
                .resizable()
                .scaledToFit()
                .foregroundStyle(theme.overlay0)
                .frame(
                    width: ChromeMetrics.ChatPopover.Status.paneChipIconSize.width,
                    height: ChromeMetrics.ChatPopover.Status.paneChipIconSize.height
                )
            Text(paneName)
                .font(ChromeType.chatPopoverChipLabel)
                .foregroundStyle(theme.subtext0)
                .lineLimit(1)
        }
        .padding(.vertical, ChromeMetrics.ChatPopover.Status.paneChipVerticalPadding)
        .padding(.horizontal, ChromeMetrics.ChatPopover.Status.paneChipHorizontalPadding)
        .frame(
            width: ChromeMetrics.ChatPopover.Status.paneChipSize.width,
            height: ChromeMetrics.ChatPopover.Status.paneChipSize.height, alignment: .leading
        )
        .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.Status.paneChipCornerRadius).fill(Color(theme.palette.surface0)))
    }

    private func roomChip(_ room: String) -> some View {
        Text(room)
            .font(ChromeType.chatPopoverChipLabel)
            .foregroundStyle(theme.overlay0)
            .padding(.vertical, ChromeMetrics.ChatPopover.Status.roomChipVerticalPadding)
            .padding(.horizontal, ChromeMetrics.ChatPopover.Status.roomChipHorizontalPadding)
            .frame(height: ChromeMetrics.ChatPopover.Status.roomChipHeight)
            .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.Status.roomChipCornerRadius).fill(Color(theme.palette.activeRowBg)))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(ChromeType.chatPopoverSectionLabel)
            .foregroundStyle(theme.overlay0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, ChromeMetrics.ChatPopover.SectionLabel.topPadding)
            .padding(.trailing, ChromeMetrics.ChatPopover.SectionLabel.trailingPadding)
            .padding(.bottom, ChromeMetrics.ChatPopover.SectionLabel.bottomPadding)
            .padding(.leading, ChromeMetrics.ChatPopover.SectionLabel.leadingPadding)
            .frame(width: ChromeMetrics.ChatPopover.width, height: ChromeMetrics.ChatPopover.SectionLabel.height, alignment: .top)
    }

    var featuresBlock: some View {
        VStack(spacing: 0) {
            ForEach(ChatPopoverFeature.allCases) { feature in
                featureRow(feature)
            }
        }
        .padding(.horizontal, ChromeMetrics.ChatPopover.Features.horizontalInset)
        .frame(width: ChromeMetrics.ChatPopover.width, height: ChromeMetrics.ChatPopover.Features.bandHeight)
    }

    private func featureRow(_ feature: ChatPopoverFeature) -> some View {
        let isHighlighted = hoveredFeature == feature
        return Button(action: { select(feature) }) {
            HStack(spacing: ChromeMetrics.ChatPopover.Features.rowGap) {
                Image(systemName: feature.symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isHighlighted ? theme.accent : theme.overlay0)
                    .frame(width: ChromeMetrics.ChatPopover.Features.iconSize.width, height: ChromeMetrics.ChatPopover.Features.iconSize.height)
                Text(feature.title)
                    .font(ChromeType.chatPopoverFeatureName)
                    .foregroundStyle(theme.text)
                Spacer(minLength: 0)
                Text(feature.shortcut)
                    .font(ChromeType.chatPopoverFeatureShortcut)
                    .foregroundStyle(theme.overlay0)
            }
            .padding(.horizontal, ChromeMetrics.ChatPopover.Features.rowHorizontalPadding)
            .frame(width: ChromeMetrics.ChatPopover.Features.rowSize.width, height: ChromeMetrics.ChatPopover.Features.rowSize.height)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.Features.rowCornerRadius)
                    .fill(isHighlighted ? Color(theme.palette.selectionBg) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredFeature = hovering ? feature : (hoveredFeature == feature ? nil : hoveredFeature) }
    }

    private func select(_ feature: ChatPopoverFeature) {
        if feature == .openViewer {
            openViewer()
        } else {
            route = .feature(feature)
        }
    }

    private func openViewer() {
        onOpenViewer()
        isPresented = false
    }

    var signButtonsBlock: some View {
        HStack(spacing: ChromeMetrics.ChatPopover.SignButtons.gap) {
            signButton(
                title: "Sign in", symbolName: "rectangle.portrait.and.arrow.forward",
                state: signButtonStates.signIn, action: onSignIn
            )
            signButton(
                title: "Sign out", symbolName: "rectangle.portrait.and.arrow.right",
                state: signButtonStates.signOut, action: onSignOut
            )
        }
        .padding(.top, ChromeMetrics.ChatPopover.SignButtons.topPadding)
        .padding(.trailing, ChromeMetrics.ChatPopover.SignButtons.trailingPadding)
        .padding(.bottom, ChromeMetrics.ChatPopover.SignButtons.bottomPadding)
        .padding(.leading, ChromeMetrics.ChatPopover.SignButtons.leadingPadding)
        .frame(width: ChromeMetrics.ChatPopover.width, height: ChromeMetrics.ChatPopover.SignButtons.bandHeight, alignment: .top)
    }

    /// A pane with no status yet is neither signed in nor out: rather than
    /// fabricate a `ChatStatus` to hand `ChatPresence.buttons(for:)`, both
    /// buttons read as secondary until a real status arrives.
    private var signButtonStates: (signIn: ButtonState, signOut: ButtonState) {
        guard let status else { return (.secondary, .secondary) }
        return ChatPresence.buttons(for: status)
    }

    private func signButton(title: String, symbolName: String, state: ButtonState, action: @escaping () -> Void) -> some View {
        let isPrimary = state == .primary
        let foreground = isPrimary ? Color(theme.palette.panelBg) : theme.subtext0
        return Button(action: action) {
            HStack(spacing: ChromeMetrics.ChatPopover.SignButtons.contentGap) {
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: ChromeMetrics.ChatPopover.SignButtons.iconSize.width,
                        height: ChromeMetrics.ChatPopover.SignButtons.iconSize.height
                    )
                Text(title)
                    .font(isPrimary ? ChromeType.chatPopoverButtonLabelPrimary : ChromeType.chatPopoverButtonLabelSecondary)
            }
            .foregroundStyle(foreground)
            .frame(width: ChromeMetrics.ChatPopover.SignButtons.buttonSize.width, height: ChromeMetrics.ChatPopover.SignButtons.buttonSize.height)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.SignButtons.cornerRadius)
                    .fill(isPrimary ? theme.accent : Color(theme.palette.surface0))
            )
            .overlay {
                // An accent fill needs no edge to be found against the
                // popover's ground; the dark secondary fill does.
                if !isPrimary {
                    RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.SignButtons.cornerRadius)
                        .strokeBorder(Color(theme.palette.surface1), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feature route

    /// What Broadcast, Peek and Quick send fall back to until each has its
    /// own body: a back chevron and the feature's own title, at the same
    /// header height the status route uses. The real bodies are each a
    /// separate view hung off `ChatPopoverFeature`; this carries only the
    /// affordance back to the status route.
    private func featurePlaceholder(_ feature: ChatPopoverFeature) -> some View {
        HStack(spacing: ChromeMetrics.ChatPopover.Features.rowGap) {
            Button(action: { route = .status }) {
                Image(systemName: "chevron.left")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(theme.overlay0)
                    .frame(width: ChromeMetrics.ChatPopover.Features.iconSize.width, height: ChromeMetrics.ChatPopover.Features.iconSize.height)
            }
            .buttonStyle(.plain)
            Text(feature.title)
                .font(ChromeType.chatPopoverTitle)
                .foregroundStyle(theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ChromeMetrics.ChatPopover.Header.horizontalPadding)
        .frame(width: ChromeMetrics.ChatPopover.width, height: ChromeMetrics.ChatPopover.Header.height)
    }
}

/// Consumes Esc only when it actually closes this popover, the same
/// precedence `RearrangeModeMachine.handleEscape` gives rearrange mode.
/// Scoped to the popover's OWN window (`event.window === window`): the
/// monitor exists only while this content view is mounted, so an Esc typed
/// anywhere else -- above all the pane's own terminal window -- never reaches
/// it and is never at risk of being swallowed here.
private struct ChatPopoverEscMonitor: NSViewRepresentable {
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(view, isPresented: $isPresented) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(nsView, isPresented: $isPresented)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private var monitor: Any?
        private weak var monitoredWindow: NSWindow?

        @MainActor
        func attach(_ view: NSView, isPresented: Binding<Bool>) {
            guard let window = view.window, monitoredWindow !== window else { return }
            detach()
            monitoredWindow = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === window, Int(event.keyCode) == kVK_Escape else { return event }
                var presented = isPresented.wrappedValue
                let consumed = ChatPopoverEsc.handle(isPresented: &presented)
                isPresented.wrappedValue = presented
                return consumed ? nil : event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            monitoredWindow = nil
        }

        deinit { detach() }
    }
}
