import Foundation
import Observation

/// Which top-bar workspace the overlay shows; one at a time.
@MainActor
@Observable
public final class TopBarOverlayStore {
    public private(set) var openPin: PinID?

    public init() {}

    public func open(_ id: PinID) { openPin = id }

    public func close() { openPin = nil }
}

/// Why a workspace could not move to the top bar: it holds more than the one
/// tab a top-bar workspace shows.
public struct TopBarRefusal: Equatable, Sendable {
    public let name: String
    public let tabs: Int

    public init(name: String, tabs: Int) {
        self.name = name
        self.tabs = tabs
    }

    public var title: String { "\u{201C}\(name)\u{201D} can\u{2019}t move to the top bar" }

    public var message: String {
        "Top-bar workspaces show a single view, so they hold one tab. \u{201C}\(name)\u{201D} has \(tabs) tabs: close the extras, then move it."
    }
}
