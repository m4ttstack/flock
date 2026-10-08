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
