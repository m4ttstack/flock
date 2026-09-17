import Foundation
import Observation

/// The subset of `HerdrClient` the coordinator needs; `HerdrClient` conforms
/// below. Narrowed to just this one verb so a `HerdrCommandClient` test
/// double built for `SessionViewModelTests` never has to implement it.
public protocol LayoutExportClient: Sendable {
    func layoutExport(tabID: TabID) async throws -> ExportedLayoutDescription
}

extension HerdrClient: LayoutExportClient {}

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
@Observable
public final class LayoutExportCoordinator {
    public private(set) var exportedLayouts: [TabID: ExportedLayoutDescription] = [:]
    public private(set) var fallbackTabs: Set<TabID> = []

    private let client: any LayoutExportClient
    private var signatures: [TabID: LayoutTopologySignature] = [:]
    private var refreshTask: Task<Void, Never>?
    // Compared against the incoming `selectedTabID` in the pre-check below;
    // content-churn ticks with nothing changed and no selection change never
    // reach `refreshTask?.cancel()` at all.
    private var lastSelectedTabID: TabID?

    public init(client: any LayoutExportClient) {
        self.client = client
    }

    /// `tabIDsInOrder` is the caller's own tab ordering (e.g. the tab bar);
    /// `selectedTabID`, when present in that list, is moved to the front.
    ///
    /// Called at the tail of every model tick, content churn included, so it
    /// must not cancel/respawn when there is nothing to do: doing so on every
    /// tick would itself become the uncoalesced-round-trips shape the
    /// postmortem warns about, one rapid cancel/respawn cycle per tick rather
    /// than per real layout change. The pre-check below skips straight
    /// through when no tab's signature changed and the selected tab is the
    /// same as last time; `refetchIfNeeded`'s own commit guard is the second
    /// line of defense, for the rarer case where a fetch does get superseded
    /// mid-flight.
    public func refresh(tabIDsInOrder: [TabID], layouts: [TabID: LayoutSnapshot], selectedTabID: TabID?) {
        let order = Self.fetchOrder(tabIDsInOrder: tabIDsInOrder, selectedTabID: selectedTabID)
        guard selectedTabID != lastSelectedTabID || hasSignatureChange(order: order, layouts: layouts) else {
            return
        }
        lastSelectedTabID = selectedTabID
        refreshTask?.cancel()
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

    private func hasSignatureChange(order: [TabID], layouts: [TabID: LayoutSnapshot]) -> Bool {
        order.contains { tabID in
            guard let layout = layouts[tabID] else { return false }
            return signatures[tabID] != LayoutTopologySignature(layout: layout)
        }
    }

    /// `priorSignature` is read once, before the fetch goes out, and compared
    /// again immediately before the write below: if anything else committed
    /// for this tab while this fetch was in flight -- a fresher task that
    /// won the race, or this task having since been cancelled -- that
    /// comparison fails and this result is discarded rather than clobbering
    /// whatever is now current. This is the guard a signature-only precheck
    /// cannot provide: cancellation is cooperative and only observed between
    /// loop iterations, so a superseded fetch already past its `await` when
    /// cancelled must still be stopped from writing on the way out.
    private func refetchIfNeeded(tabID: TabID, layout: LayoutSnapshot) async {
        let signature = LayoutTopologySignature(layout: layout)
        let priorSignature = signatures[tabID]
        if priorSignature == signature { return }
        do {
            let exported = try await client.layoutExport(tabID: tabID)
            guard !Task.isCancelled, signatures[tabID] == priorSignature else { return }
            exportedLayouts[tabID] = exported
            fallbackTabs.remove(tabID)
            signatures[tabID] = signature
        } catch {
            guard !Task.isCancelled, signatures[tabID] == priorSignature else { return }
            exportedLayouts[tabID] = nil
            fallbackTabs.insert(tabID)
        }
    }
}
