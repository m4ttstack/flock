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
/// Each setting is its own `Section`, never folded into another's. Each tab
/// is as tall as what it holds, so none scrolls.
struct FlockSettingsView: View {
    /// Wide enough that a setting's description and its control share a row
    /// without the description wrapping to three lines.
    static let width: CGFloat = 620

    let herdrMousePatchStore: HerdrMousePatchStore
    let notificationLifetimeStore: NotificationLifetimeStore
    let missionBottomLineStore: MissionBottomLineStore
    let overviewReturnStore: OverviewReturnStore
    let oneTitleStore: OneTitleStore
    let rearrangeAfterMoveStore: RearrangeAfterMoveStore
    let startingFolderStore: StartingFolderStore
    let rtModalTextSizeStore: RtModalTextSizeStore
    let commandLineToolStore: CommandLineToolStore

    @State private var tab: SettingsTab
    /// Each tab's measured height, which the window is fitted to.
    @State private var heights: [SettingsTab: CGFloat] = [:]

    init(
        herdrMousePatchStore: HerdrMousePatchStore, notificationLifetimeStore: NotificationLifetimeStore,
        missionBottomLineStore: MissionBottomLineStore, overviewReturnStore: OverviewReturnStore,
        oneTitleStore: OneTitleStore, rearrangeAfterMoveStore: RearrangeAfterMoveStore,
        startingFolderStore: StartingFolderStore, rtModalTextSizeStore: RtModalTextSizeStore,
        commandLineToolStore: CommandLineToolStore, tab: SettingsTab = .general
    ) {
        self.herdrMousePatchStore = herdrMousePatchStore
        self.notificationLifetimeStore = notificationLifetimeStore
        self.missionBottomLineStore = missionBottomLineStore
        self.overviewReturnStore = overviewReturnStore
        self.oneTitleStore = oneTitleStore
        self.rearrangeAfterMoveStore = rearrangeAfterMoveStore
        self.startingFolderStore = startingFolderStore
        self.rtModalTextSizeStore = rtModalTextSizeStore
        self.commandLineToolStore = commandLineToolStore
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            pane(.general) {
                StartingFolderSettingsSection(store: startingFolderStore)
                NotificationSettingsSection(store: notificationLifetimeStore)
                TitlesSettingsSection(store: oneTitleStore)
            }
            .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
            .tag(SettingsTab.general)
            pane(.views) {
                OverviewSettingsSection(bottomLineStore: missionBottomLineStore, returnStore: overviewReturnStore)
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
                HerdrMousePatchRow(store: herdrMousePatchStore)
            }
            .tabItem { Label(SettingsTab.herdr.title, systemImage: SettingsTab.herdr.symbol) }
            .tag(SettingsTab.herdr)
        }
        .frame(width: Self.width)
        .background(SettingsWindowRegistration(width: Self.width, height: heights[tab]))
        .onAppear {
            herdrMousePatchStore.refresh()
            commandLineToolStore.refresh()
        }
    }

    /// One tab's sections, as tall as they are and measured: a grouped form
    /// scrolls by default and offers the window no height of its own. Held
    /// to the top, so a window taller than the tab never centres it.
    private func pane<Content: View>(_ tab: SettingsTab, @ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[tab] = $0 }
            .frame(width: Self.width)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
