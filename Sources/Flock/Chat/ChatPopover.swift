import AppKit
import Carbon.HIToolbox
import FlockCore
import SwiftUI

/// One of the rows the FEATURES band lists, each carrying its own shortcut
/// and glyph. `chevron.left`/`xmark`, the two icons every sub-view's own
/// header carries, are not here: nothing in this enum routes to them.
enum ChatPopoverFeature: CaseIterable, Identifiable {
    case broadcast
    case peek
    case quickSend
    case openViewer
    case slackSupport

    var id: Self { self }

    var title: String {
        switch self {
        case .broadcast: "Broadcast to panes"
        case .peek: "Chat peek"
        case .quickSend: "Quick send"
        case .slackSupport: "Slack support"
        case .openViewer: "Open viewer"
        }
    }

    /// Slack support is reached only from its row, so it has no shortcut.
    var shortcut: String? {
        switch self {
        case .broadcast: "⌘⇧B"
        case .peek: "⌘⇧P"
        case .quickSend: "⌘⇧S"
        case .slackSupport: nil
        case .openViewer: "⌘⇧V"
        }
    }

    var symbolName: String {
        switch self {
        case .broadcast: "dot.radiowaves.left.and.right"
        case .peek: "person.2.fill"
        case .quickSend: "paperplane.fill"
        case .slackSupport: "bubble.left.and.bubble.right.fill"
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
    let status: ChatStatus?
    /// Set only when this pane's last status call failed: chat is available
    /// (this view exists at all), the call itself is what is broken, never
    /// read as the pane being merely signed out.
    let statusError: String?
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onOpenViewer: () -> Void
    /// Non-nil disables Open Viewer alone and names why, on both the header
    /// icon and the feature row -- every other row keeps working.
    let viewerDisabledReason: String?
    let onRetry: () -> Void
    /// Peek's own jump affordance: the pane id its `jump` call resolves,
    /// handed back so the caller can focus it FROM FLOCK'S OWN MODEL. A
    /// no-op default keeps every existing call site (render tests included)
    /// compiling; only the real pane chrome supplies the real one. Nil hides
    /// the jump (see `ChatPeekView`).
    let onJump: ((PaneID) -> Void)?
    /// Nil hides every Slack control: chat is not signed in here, or this
    /// herdr-chat has no Slack support.
    let slackRow: ChatSlackRow?
    let slackRepos: [ChatSlackRepo]
    let onStartSlackChat: (_ person: String, _ problem: String, _ repo: ChatSlackRepo) async -> Bool
    let onEndSlackChat: () -> Void

    @Binding private var isPresented: Bool
    @State private var route: Route = .status
    @State private var hoveredFeature: ChatPopoverFeature?
    @State private var isSignHovered = false

    enum Route: Equatable {
        case status
        case feature(ChatPopoverFeature)
    }

    /// Not `private`: a test reads this directly to pin `initialFeature`
    /// actually landing where it says, without hosting a window. Read-only
    /// from outside -- the chevron, Esc and `select(_:)` are the only
    /// writers.
    var currentRoute: Route { route }

    /// `initialFeature` is a global chat command's route: set, the popover
    /// opens straight onto that feature's own sub-view instead of the status
    /// root, since a shortcut names an action and has to deliver it. Read
    /// only at construction, the same as SwiftUI `@State` always is -- the
    /// chevron and Esc still drive `route` locally from there on.
    ///
    /// `previewHoveredFeature` exists only so a render test can sample the
    /// hovered/selected row's exact fill and icon colour without simulating a
    /// real pointer -- production call sites never pass it, and hovering
    /// updates the same `hoveredFeature` state afterward regardless.
    init(
        theme: Theme, status: ChatStatus?, statusError: String? = nil, isPresented: Binding<Bool>,
        onSignIn: @escaping () -> Void, onSignOut: @escaping () -> Void, onOpenViewer: @escaping () -> Void,
        viewerDisabledReason: String? = nil, onRetry: @escaping () -> Void = {}, initialFeature: ChatPopoverFeature? = nil,
        onJump: ((PaneID) -> Void)? = { _ in }, previewHoveredFeature: ChatPopoverFeature? = nil,
        slackRow: ChatSlackRow? = nil, slackRepos: [ChatSlackRepo] = [],
        onStartSlackChat: @escaping (_ person: String, _ problem: String, _ repo: ChatSlackRepo) async -> Bool = { _, _, _ in false },
        onEndSlackChat: @escaping () -> Void = {}
    ) {
        self.theme = theme
        self.status = status
        self.statusError = statusError
        self._isPresented = isPresented
        self.onSignIn = onSignIn
        self.onSignOut = onSignOut
        self.onOpenViewer = onOpenViewer
        self.viewerDisabledReason = viewerDisabledReason
        self.onRetry = onRetry
        self.onJump = onJump
        self.slackRow = slackRow
        self.slackRepos = slackRepos
        self.onStartSlackChat = onStartSlackChat
        self.onEndSlackChat = onEndSlackChat
        self._route = State(initialValue: initialFeature.map(Route.feature) ?? .status)
        self._hoveredFeature = State(initialValue: previewHoveredFeature)
    }

    var body: some View {
        Group {
            switch route {
            case .status: statusRoute
            case let .feature(feature): featureBody(feature)
            }
        }
        .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius).fill(LauncherStripStyle(theme: theme).band))
        .overlay(
            RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius)
                .strokeBorder(theme.hair, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.cornerRadius))
        .background(ChatPopoverEscMonitor(isPresented: $isPresented, isDrilledIn: isDrilledIn))
        .background(PopoverAppearancePin(isDark: !ChromeRoles.isLight(panelBg: theme.palette.panelBg)))
    }

    /// What Esc steps back from: open on a feature sub-view, one press
    /// returns to the status root rather than closing the popover outright,
    /// the same destination the chevron itself gives.
    private var isDrilledIn: Binding<Bool> {
        Binding(get: { route != .status }, set: { if !$0 { route = .status } })
    }

    private var hasRooms: Bool { status?.signedIn == true }

    // MARK: - Status route

    var statusRoute: some View {
        VStack(spacing: 0) {
            header
            failureBanner
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
            .disabled(viewerDisabledReason != nil)
            .help(viewerDisabledReason ?? "")
        }
        .padding(.vertical, ChromeMetrics.ChatPopover.Header.verticalPadding)
        .padding(.horizontal, ChromeMetrics.ChatPopover.Header.horizontalPadding)
        .frame(width: ChromeMetrics.ChatPopover.width)
        .overlay(alignment: .bottom) { bandRule }
    }

    /// Not governed by `measurements.md` -- the designs never modelled a
    /// broken machine -- so this draws only when `statusError` is set and
    /// costs zero height otherwise, leaving every existing band measurement
    /// untouched.
    @ViewBuilder
    private var failureBanner: some View {
        if let statusError {
            HStack(spacing: ChromeMetrics.ChatPopover.Status.gap) {
                Text(statusError)
                    .font(ChromeType.chatPopoverStateWord)
                    .foregroundStyle(theme.red)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(ChromeType.chatPopoverFeatureShortcut)
                    .foregroundStyle(theme.textStrong)
            }
            .padding(.vertical, ChromeMetrics.ChatPopover.Status.gap)
            .padding(.horizontal, ChromeMetrics.ChatPopover.Status.leadingPadding)
            .frame(width: ChromeMetrics.ChatPopover.width, alignment: .leading)
            .overlay(alignment: .bottom) { bandRule }
        }
    }

    var statusBlock: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.ChatPopover.Status.gap) {
            HStack(spacing: ChromeMetrics.ChatPopover.Status.gap) {
                Circle()
                    .fill(status?.signedIn == true ? theme.green : theme.overlay0)
                    .frame(width: ChromeMetrics.ChatPopover.Status.dotSize, height: ChromeMetrics.ChatPopover.Status.dotSize)
                if let name = status?.displayName {
                    Text(name)
                        .font(ChromeType.chatPopoverHandle)
                        .foregroundStyle(theme.text)
                }
                // rt's own vocabulary, never re-worded; empty until a status
                // has actually loaded for this pane.
                Text(status?.state ?? "")
                    .font(ChromeType.chatPopoverStateWord)
                    .foregroundStyle(theme.subtext0)
                Spacer(minLength: 0)
            }
            if hasRooms {
                HStack(spacing: ChromeMetrics.ChatPopover.Status.roomChipGap) {
                    ForEach(status?.rooms ?? [], id: \.self) { room in
                        roomChip(room)
                    }
                }
            }
            slackLine
        }
        .padding(.top, ChromeMetrics.ChatPopover.Status.topPadding)
        .padding(.trailing, ChromeMetrics.ChatPopover.Status.trailingPadding)
        .padding(.bottom, ChromeMetrics.ChatPopover.Status.bottomPadding)
        .padding(.leading, ChromeMetrics.ChatPopover.Status.leadingPadding)
        .frame(
            width: ChromeMetrics.ChatPopover.width,
            height: statusHeight,
            alignment: .top
        )
        .overlay(alignment: .bottom) { bandRule }
    }

    private var statusHeight: CGFloat {
        let status = ChromeMetrics.ChatPopover.Status.self
        let base = hasRooms ? status.heightSignedIn : status.heightSignedOut
        return slackLineIsShown ? base + status.slackLineHeight + status.slackLineGap : base
    }

    private var slackLineIsShown: Bool {
        switch slackRow {
        case .opening, .open, .closing: true
        case .available, nil: false
        }
    }

    /// A live chat is part of this pane's chat state, so it reads under the
    /// identity rather than beside Sign out.
    @ViewBuilder
    private var slackLine: some View {
        if let slackRow, slackLineIsShown {
            HStack(spacing: ChromeMetrics.ChatPopover.Status.gap) {
                slackLineIcon(slackRow)
                slackLineText(slackRow)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if case .open = slackRow { endChatButton }
            }
            .frame(height: ChromeMetrics.ChatPopover.Status.slackLineHeight)
        }
    }

    @ViewBuilder
    private func slackLineIcon(_ row: ChatSlackRow) -> some View {
        if case .open = row {
            Image(systemName: ChatPopoverFeature.slackSupport.symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(theme.green)
                .frame(width: ChromeMetrics.ChatPopover.Status.slackIconSize, height: ChromeMetrics.ChatPopover.Status.slackIconSize)
        } else {
            ChatSpinner(
                color: row == .opening ? theme.yellow : theme.overlay0, size: ChromeMetrics.ChatPopover.Status.slackIconSize
            )
        }
    }

    private func slackLineText(_ row: ChatSlackRow) -> some View {
        let name = { (value: String) in Text(value).font(ChromeType.chatPopoverButtonLabel) }
        return Group {
            switch row {
            case let .open(person):
                Text("Talking to \(name(person)) on Slack").foregroundStyle(theme.text)
            case let .closing(person):
                Text("Closing chat with \(name(person))").foregroundStyle(theme.subtext0)
            case .opening, .available:
                Text("Opening Slack chat…").foregroundStyle(theme.subtext0)
            }
        }
        .font(ChromeType.chatPopoverFeatureName)
    }

    private var endChatButton: some View {
        Button(action: onEndSlackChat) {
            Text("End chat")
                .font(ChromeType.chatQuickSendChipSelected)
                .foregroundStyle(theme.red)
                .padding(.vertical, ChromeMetrics.ChatPopover.Status.slackButtonVerticalPadding)
                .padding(.horizontal, ChromeMetrics.ChatPopover.Status.slackButtonHorizontalPadding)
                .background(
                    RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.Status.slackButtonCornerRadius)
                        .fill(theme.lift)
                )
        }
        .buttonStyle(.plain)
        .help("End this Slack chat")
    }

    /// The header and the status band are the only bands the popover rules
    /// off: a 1pt `hair`, never the outer stroke's own colour.
    private var bandRule: some View {
        Rectangle().fill(theme.hair).frame(height: 1)
    }

    private func roomChip(_ room: String) -> some View {
        Text(room)
            .font(ChromeType.chatPopoverChipLabel)
            .foregroundStyle(theme.textLabel)
            .padding(.vertical, ChromeMetrics.ChatPopover.Status.roomChipVerticalPadding)
            .padding(.horizontal, ChromeMetrics.ChatPopover.Status.roomChipHorizontalPadding)
            .frame(height: ChromeMetrics.ChatPopover.Status.roomChipHeight)
            .background(RoundedRectangle(cornerRadius: ChromeMetrics.ChatPopover.Status.roomChipCornerRadius).fill(theme.lift))
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
            ForEach(visibleFeatures) { feature in
                featureRow(feature)
            }
        }
        .padding(.horizontal, ChromeMetrics.ChatPopover.Features.horizontalInset)
        .frame(width: ChromeMetrics.ChatPopover.width, height: featuresHeight)
    }

    private var visibleFeatures: [ChatPopoverFeature] {
        ChatPopoverFeature.allCases.filter { $0 != .slackSupport || slackRow != nil }
    }

    private var featuresHeight: CGFloat {
        let extraRows = CGFloat(visibleFeatures.count - 4)
        return ChromeMetrics.ChatPopover.Features.bandHeight + extraRows * ChromeMetrics.ChatPopover.Features.rowSize.height
    }

    private func disabledReason(_ feature: ChatPopoverFeature) -> String? {
        switch feature {
        case .openViewer: viewerDisabledReason
        case .slackSupport: slackRow == .available ? nil : "One Slack chat per pane"
        case .broadcast, .peek, .quickSend: nil
        }
    }

    private func featureRow(_ feature: ChatPopoverFeature) -> some View {
        let isHighlighted = hoveredFeature == feature
        let disabledReason = disabledReason(feature)
        let isDisabled = disabledReason != nil
        return Button(action: { select(feature) }) {
            HStack(spacing: ChromeMetrics.ChatPopover.Features.rowGap) {
                Image(systemName: feature.symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isDisabled ? theme.overlay0 : (isHighlighted ? theme.textStrong : theme.textLabel))
                    .frame(width: ChromeMetrics.ChatPopover.Features.iconSize.width, height: ChromeMetrics.ChatPopover.Features.iconSize.height)
                Text(feature.title)
                    .font(ChromeType.chatPopoverFeatureName)
                    .foregroundStyle(isDisabled ? theme.overlay0 : theme.text)
                Spacer(minLength: 0)
                if let shortcut = feature.shortcut {
                    Text(shortcut)
                        .font(ChromeType.chatPopoverFeatureShortcut)
                        .foregroundStyle(theme.overlay0)
                } else if !isDisabled {
                    Image(systemName: "chevron.right")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(theme.overlay0)
                        .frame(width: ChromeMetrics.ChatPopover.Features.chevronSize.width, height: ChromeMetrics.ChatPopover.Features.chevronSize.height)
                }
            }
            .padding(.horizontal, ChromeMetrics.ChatPopover.Features.rowHorizontalPadding)
            .frame(width: ChromeMetrics.ChatPopover.Features.rowSize.width, height: ChromeMetrics.ChatPopover.Features.rowSize.height)
            .background {
                if isHighlighted && !isDisabled {
                    HoverWashFill(theme: theme, cornerRadius: ChromeMetrics.ChatPopover.Features.rowCornerRadius)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(disabledReason ?? "")
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

    private var signOutIsBlocked: Bool { slackRow?.blocksSignOut ?? false }

    var signButtonsBlock: some View {
        VStack(spacing: ChromeMetrics.ChatPopover.SignButtons.hintGap) {
            signButton(for: ChatPresence.signAction(for: status))
            if signOutIsBlocked {
                Text("End the Slack chat first")
                    .font(ChromeType.chatComposeFooterHint)
                    .foregroundStyle(theme.overlay0)
                    .frame(height: ChromeMetrics.ChatPopover.SignButtons.hintHeight)
            }
        }
        .padding(.top, ChromeMetrics.ChatPopover.SignButtons.topPadding)
        .padding(.horizontal, ChromeMetrics.ChatPopover.Features.horizontalInset)
        .padding(.bottom, ChromeMetrics.ChatPopover.SignButtons.bottomPadding)
        .frame(width: ChromeMetrics.ChatPopover.width, height: signButtonsHeight, alignment: .top)
    }

    private var signButtonsHeight: CGFloat {
        let band = ChromeMetrics.ChatPopover.SignButtons.self
        return signOutIsBlocked ? band.bandHeight + band.hintGap + band.hintHeight : band.bandHeight
    }

    private func signButton(for signAction: ChatSignAction) -> some View {
        let title: String
        let symbolName: String
        let isEnabled: Bool
        let action: () -> Void
        switch signAction {
        case let .signIn(enabled):
            title = "Sign in"
            symbolName = "rectangle.portrait.and.arrow.forward"
            isEnabled = enabled
            action = onSignIn
        case .signOut:
            title = "Sign out"
            symbolName = "rectangle.portrait.and.arrow.right"
            isEnabled = !signOutIsBlocked
            action = onSignOut
        }
        // A row like the features above it rather than a filled button: the
        // popover's one action should not outweigh everything it offers.
        let features = ChromeMetrics.ChatPopover.Features.self
        return Button(action: action) {
            HStack(spacing: features.rowGap) {
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isEnabled ? (isSignHovered ? theme.textStrong : theme.textLabel) : theme.overlay0)
                    .frame(width: features.iconSize.width, height: features.iconSize.height)
                Text(title)
                    .font(ChromeType.chatPopoverFeatureName)
                    .foregroundStyle(isEnabled ? theme.text : theme.overlay0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, features.rowHorizontalPadding)
            .frame(height: features.rowSize.height)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: features.rowCornerRadius)
                    .fill(isSignHovered && isEnabled ? theme.lift : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isSignHovered = $0 }
        .disabled(!isEnabled)
    }

    // MARK: - Feature route

    /// Broadcast and Quick send never reach the `.openViewer` arm: `select`
    /// intercepts it before `route` is ever set to it, so it renders nothing
    /// rather than a fourth sub-view.
    private func featureBody(_ feature: ChatPopoverFeature) -> some View {
        let onBack = { route = .status }
        let onClose = { isPresented = false }
        return Group {
            switch feature {
            case .broadcast:
                ChatBroadcastView(theme: theme, onBack: onBack, onClose: onClose)
            case .peek:
                ChatPeekView(theme: theme, onBack: onBack, onClose: onClose, onJump: onJump)
            case .quickSend:
                ChatQuickSendView(theme: theme, status: status, onBack: onBack, onClose: onClose)
            case .slackSupport:
                ChatSlackSupportView(theme: theme, repos: slackRepos, onBack: onBack, onClose: onClose, onStart: onStartSlackChat)
            case .openViewer:
                EmptyView()
            }
        }
    }
}

/// Consumes Esc only when it actually leaves a level of this popover (a
/// feature sub-view stepping back, or the root closing outright), the same
/// precedence `RearrangeModeMachine.handleEscape` gives rearrange mode.
/// Scoped to the popover's OWN window (`event.window === window`): the
/// monitor exists only while this content view is mounted, so an Esc typed
/// anywhere else -- above all the pane's own terminal window -- never reaches
/// it and is never at risk of being swallowed here.
private struct ChatPopoverEscMonitor: NSViewRepresentable {
    @Binding var isPresented: Bool
    @Binding var isDrilledIn: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(view, isPresented: $isPresented, isDrilledIn: $isDrilledIn) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(nsView, isPresented: $isPresented, isDrilledIn: $isDrilledIn)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private var monitor: Any?
        private weak var monitoredWindow: NSWindow?

        @MainActor
        func attach(_ view: NSView, isPresented: Binding<Bool>, isDrilledIn: Binding<Bool>) {
            guard let window = view.window, monitoredWindow !== window else { return }
            detach()
            monitoredWindow = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === window, Int(event.keyCode) == kVK_Escape else { return event }
                var presented = isPresented.wrappedValue
                var drilledIn = isDrilledIn.wrappedValue
                let consumed = ChatPopoverEsc.handle(isPresented: &presented, isDrilledIn: &drilledIn)
                isPresented.wrappedValue = presented
                isDrilledIn.wrappedValue = drilledIn
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
