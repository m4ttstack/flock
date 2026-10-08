import FlockCore
import SwiftUI

/// The Settings window's tabs, in toolbar order.
enum SettingsTab: String, CaseIterable, Hashable {
    case general, views, tools, herdr

    var title: String {
        switch self {
        case .general: "General"
        case .views: "Views"
        case .tools: "Tools"
        case .herdr: "herdr"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .views: "square.grid.2x2"
        case .tools: "wrench.and.screwdriver"
        case .herdr: "terminal"
        }
    }
}

/// flock's Settings window (Cmd-,), in the system's own settings chrome
/// rather than the app's. A settings window is one of the few surfaces a
/// macOS user expects to look like every other app's, so this takes the
/// toolbar tabs, `Form`'s grouped style and the system appearance and none
/// of flock's theme: a dark card floating in an oversized window read as a
/// dialog that had escaped from somewhere else.
///
/// Each setting is its own `Section`, never folded into another's. Every tab
/// is the same size, so switching tabs never moves the window: a shorter tab
/// leaves room below, a longer one scrolls.
struct FlockSettingsView: View {
    /// Wide enough that a setting's description and its control share a row
    /// without the description wrapping to three lines; tall enough for
    /// General, the longest tab, with a custom folder showing.
    static let size = CGSize(width: 560, height: 520)

    let herdrMousePatchStore: HerdrMousePatchStore
    let notificationLifetimeStore: NotificationLifetimeStore
    let missionBottomLineStore: MissionBottomLineStore
    let overviewReturnStore: OverviewReturnStore
    let overviewInclusionStore: OverviewInclusionStore
    let oneTitleStore: OneTitleStore
    let topBarLabelStore: TopBarLabelStore
    let rearrangeAfterMoveStore: RearrangeAfterMoveStore
    let startingFolderStore: StartingFolderStore
    let rtModalTextSizeStore: RtModalTextSizeStore
    let commandLineToolStore: CommandLineToolStore
    let herdrVersion: String?

    @State private var tab: SettingsTab

    init(
        herdrMousePatchStore: HerdrMousePatchStore, notificationLifetimeStore: NotificationLifetimeStore,
        missionBottomLineStore: MissionBottomLineStore, overviewReturnStore: OverviewReturnStore,
        overviewInclusionStore: OverviewInclusionStore,
        oneTitleStore: OneTitleStore, topBarLabelStore: TopBarLabelStore, rearrangeAfterMoveStore: RearrangeAfterMoveStore,
        startingFolderStore: StartingFolderStore, rtModalTextSizeStore: RtModalTextSizeStore,
        commandLineToolStore: CommandLineToolStore, herdrVersion: String?, tab: SettingsTab = .general
    ) {
        self.herdrMousePatchStore = herdrMousePatchStore
        self.notificationLifetimeStore = notificationLifetimeStore
        self.missionBottomLineStore = missionBottomLineStore
        self.overviewReturnStore = overviewReturnStore
        self.overviewInclusionStore = overviewInclusionStore
        self.oneTitleStore = oneTitleStore
        self.topBarLabelStore = topBarLabelStore
        self.rearrangeAfterMoveStore = rearrangeAfterMoveStore
        self.startingFolderStore = startingFolderStore
        self.rtModalTextSizeStore = rtModalTextSizeStore
        self.commandLineToolStore = commandLineToolStore
        self.herdrVersion = herdrVersion
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            pane(.general) {
                StartingFolderSettingsSection(store: startingFolderStore)
                NotificationSettingsSection(store: notificationLifetimeStore)
                TitlesSettingsSection(store: oneTitleStore)
                TopBarSettingsSection(store: topBarLabelStore)
            }
            .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
            .tag(SettingsTab.general)
            pane(.views) {
                OverviewSettingsSection(
                    bottomLineStore: missionBottomLineStore, returnStore: overviewReturnStore, inclusionStore: overviewInclusionStore
                )
                RearrangeSettingsSection(store: rearrangeAfterMoveStore)
            }
            .tabItem { Label(SettingsTab.views.title, systemImage: SettingsTab.views.symbol) }
            .tag(SettingsTab.views)
            pane(.tools) {
                RtModalTextSizeSection(store: rtModalTextSizeStore)
                CommandLineToolSection(store: commandLineToolStore)
            }
            .tabItem { Label(SettingsTab.tools.title, systemImage: SettingsTab.tools.symbol) }
            .tag(SettingsTab.tools)
            pane(.herdr) {
                HerdrMousePatchRow(store: herdrMousePatchStore, herdrVersion: herdrVersion)
            }
            .tabItem { Label(SettingsTab.herdr.title, systemImage: SettingsTab.herdr.symbol) }
            .tag(SettingsTab.herdr)
        }
        .background(SettingsWindowRegistration(contentSize: Self.size))
        .onAppear {
            herdrMousePatchStore.refresh()
            commandLineToolStore.refresh()
        }
    }

    private func pane<Content: View>(_ tab: SettingsTab, @ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .frame(width: Self.size.width, height: Self.size.height)
    }
}
