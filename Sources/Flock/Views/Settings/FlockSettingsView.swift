import FlockCore
import SwiftUI

/// The Settings window's tabs, in toolbar order.
enum SettingsTab: String, CaseIterable, Hashable {
    case general, profiles, views, tools, herdr

    var title: String {
        switch self {
        case .general: "General"
        case .profiles: "Profiles"
        case .views: "Views"
        case .tools: "Tools"
        case .herdr: "herdr"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .profiles: "person.2"
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
    let agentCloseWarningStore: AgentCloseWarningStore
    let linkTrustStore: LinkTrustStore
    let topBarLabelStore: TopBarLabelStore
    let rearrangeAfterMoveStore: RearrangeAfterMoveStore
    let startingFolderStore: StartingFolderStore
    let rtModalTextSizeStore: RtModalTextSizeStore
    let commandLineToolStore: CommandLineToolStore
    let herdrVersion: String?
    let herdrUpdateStore: HerdrUpdateStore?
    let serverPicker: ServerPicker?
    let profiles: ProfileStore?
    let isLocked: Bool
    let switchProfile: ((String) async -> Bool)?
    let changeServer: ((String?) async -> Bool)?
    let newProfileDraft: String
    let serverDraft: ServerSettingsSection.Draft?
    let profilesDraft: ProfilesSettingsSection.Draft?

    @Bindable var selection: SettingsTabSelection

    init(
        herdrMousePatchStore: HerdrMousePatchStore, notificationLifetimeStore: NotificationLifetimeStore,
        missionBottomLineStore: MissionBottomLineStore, overviewReturnStore: OverviewReturnStore,
        overviewInclusionStore: OverviewInclusionStore,
        oneTitleStore: OneTitleStore, agentCloseWarningStore: AgentCloseWarningStore, linkTrustStore: LinkTrustStore, topBarLabelStore: TopBarLabelStore, rearrangeAfterMoveStore: RearrangeAfterMoveStore,
        startingFolderStore: StartingFolderStore, rtModalTextSizeStore: RtModalTextSizeStore,
        commandLineToolStore: CommandLineToolStore, herdrVersion: String?, herdrUpdateStore: HerdrUpdateStore? = nil,
        serverPicker: ServerPicker? = nil, profiles: ProfileStore? = nil, isLocked: Bool = false,
        switchProfile: ((String) async -> Bool)? = nil, changeServer: ((String?) async -> Bool)? = nil,
        newProfileDraft: String = "", serverDraft: ServerSettingsSection.Draft? = nil, profilesDraft: ProfilesSettingsSection.Draft? = nil, tab: SettingsTab = .general, selection: SettingsTabSelection? = nil
    ) {
        self.herdrMousePatchStore = herdrMousePatchStore
        self.notificationLifetimeStore = notificationLifetimeStore
        self.missionBottomLineStore = missionBottomLineStore
        self.overviewReturnStore = overviewReturnStore
        self.overviewInclusionStore = overviewInclusionStore
        self.oneTitleStore = oneTitleStore
        self.agentCloseWarningStore = agentCloseWarningStore
        self.linkTrustStore = linkTrustStore
        self.topBarLabelStore = topBarLabelStore
        self.rearrangeAfterMoveStore = rearrangeAfterMoveStore
        self.startingFolderStore = startingFolderStore
        self.rtModalTextSizeStore = rtModalTextSizeStore
        self.commandLineToolStore = commandLineToolStore
        self.herdrVersion = herdrVersion
        self.herdrUpdateStore = herdrUpdateStore
        self.serverPicker = serverPicker
        self.profiles = profiles
        self.isLocked = isLocked
        self.switchProfile = switchProfile
        self.changeServer = changeServer
        self.newProfileDraft = newProfileDraft
        self.serverDraft = serverDraft
        self.profilesDraft = profilesDraft
        _selection = Bindable(selection ?? SettingsTabSelection(tab: tab))
    }

    var body: some View {
        TabView(selection: $selection.tab) {
            pane(.general) {
                StartingFolderSettingsSection(store: startingFolderStore)
                NotificationSettingsSection(store: notificationLifetimeStore)
                TitlesSettingsSection(store: oneTitleStore)
                TopBarSettingsSection(store: topBarLabelStore)
                ClosingSettingsSection(store: agentCloseWarningStore)
                LinkTrustSettingsSection(store: linkTrustStore)
            }
            .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
            .tag(SettingsTab.general)
            pane(.profiles) {
                if let profiles {
                    ProfilesSettingsSection(
                        profiles: profiles, picker: serverPicker, isLocked: isLocked,
                        switchProfile: switchProfile ?? { _ in false }, changeServer: changeServer ?? { _ in false },
                        selection: selection, draftName: newProfileDraft, draft: profilesDraft
                    )
                }
            }
            .tabItem { Label(SettingsTab.profiles.title, systemImage: SettingsTab.profiles.symbol) }
            .tag(SettingsTab.profiles)
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
                if let herdrUpdateStore {
                    HerdrUpdateSection(store: herdrUpdateStore)
                }
                HerdrMousePatchRow(store: herdrMousePatchStore, herdrVersion: herdrVersion)
                if let serverPicker {
                    ServerSettingsSection(picker: serverPicker, draft: serverDraft)
                    ServersSettingsSection(picker: serverPicker, profiles: profiles)
                }
            }
            .tabItem { Label(SettingsTab.herdr.title, systemImage: SettingsTab.herdr.symbol) }
            .tag(SettingsTab.herdr)
        }
        .background(SettingsWindowRegistration(contentSize: Self.size))
        .onAppear {
            herdrMousePatchStore.refresh()
            commandLineToolStore.refresh()
            Task { await herdrUpdateStore?.checkIfDue() }
        }
    }

    private func pane<Content: View>(_ tab: SettingsTab, @ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content)
            .formStyle(.grouped)
            .frame(width: Self.size.width, height: Self.size.height)
    }
}
