import Foundation

/// Keeps each tab's `layout.export` tree current so `CanvasGeometry.resolved`
/// can read herdr's own split tree instead of the rect-containment fallback.
///
/// Refetch is keyed per tab on `LayoutTopologySignature`: an unchanged tab
/// never refetches, so changing one tab's ratio never disturbs another
/// tab's cached export. A refresh always visits the selected tab first, then
/// every other tab one at a time -- never in parallel -- because herdr's own
/// postmortem is a GCD pool exhausted by uncoalesced round trips.
///
/// A failed or unrecognized-shape response leaves that tab in `fallbackTabs`
/// (the render path reads rect derivation for it) rather than crashing, and
/// its signature is left unset so the next `refresh` retries -- a protocol-22
/// server supports `layout.export`, so a failure here is treated as
/// transient, never cached as permanent.
@MainActor
public final class LayoutExportCoordinator {
    public private(set) var exportedLayouts: [TabID: ExportedLayoutDescription] = [:]
    public private(set) var fallbackTabs: Set<TabID> = []

    private let client: HerdrClient
    private var signatures: [TabID: LayoutTopologySignature] = [:]
    private var refreshTask: Task<Void, Never>?

    public init(client: HerdrClient) {
        self.client = client
    }

    /// `tabIDsInOrder` is the caller's own tab ordering (e.g. the tab bar);
    /// `selectedTabID`, when present in that list, is moved to the front.
    /// A new call cancels any refresh still in flight so a rapid tab switch
    /// never queues stale work behind fresh work.
    public func refresh(tabIDsInOrder: [TabID], layouts: [TabID: LayoutSnapshot], selectedTabID: TabID?) {
        refreshTask?.cancel()
        let order = Self.fetchOrder(tabIDsInOrder: tabIDsInOrder, selectedTabID: selectedTabID)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            for tabID in order {
                if Task.isCancelled { return }
                guard let layout = layouts[tabID] else { continue }
                await self.refetchIfNeeded(tabID: tabID, layout: layout)
            }
        }
    }

    /// Lets a test observe the end state of a `refresh` instead of racing it.
    public func waitForIdle() async {
        await refreshTask?.value
    }

    private static func fetchOrder(tabIDsInOrder: [TabID], selectedTabID: TabID?) -> [TabID] {
        guard let selectedTabID, let index = tabIDsInOrder.firstIndex(of: selectedTabID) else {
            return tabIDsInOrder
        }
        var order = tabIDsInOrder
        order.remove(at: index)
        order.insert(selectedTabID, at: 0)
        return order
    }

    private func refetchIfNeeded(tabID: TabID, layout: LayoutSnapshot) async {
        let signature = LayoutTopologySignature(layout: layout)
        if signatures[tabID] == signature { return }
        do {
            exportedLayouts[tabID] = try await client.layoutExport(tabID: tabID)
            fallbackTabs.remove(tabID)
            signatures[tabID] = signature
        } catch {
            exportedLayouts[tabID] = nil
            fallbackTabs.insert(tabID)
        }
    }
}
