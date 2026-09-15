import Foundation

@MainActor
enum LayoutPass {
    /// Runs `body` once, when the main run loop is next about to sleep, after
    /// every other before-waiting observer. AppKit's layout and display and
    /// Core Animation's commit all run from those observers, and the loop
    /// drains queued main-actor work before it sleeps, so by then SwiftUI has
    /// applied whatever geometry the current event changed and every surface
    /// has been sized to it. A plain main-actor hop can run before that pass.
    static func after(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
