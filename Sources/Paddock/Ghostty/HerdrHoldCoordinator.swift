import AppKit
import Foundation
import PaddockCore

/// Hands paddock's panes back to herdr while paddock is not the active app,
/// and takes them again when it returns.
///
/// herdr sizes a pane to whichever shell client is in front, which is why
/// focusing a Mac terminal repaints its panes to that terminal's size. Paddock
/// is not a shell client: it attaches per pane and herdr takes a
/// `direct_attach_resize_lock` that does not follow focus, so paddock's sizes
/// would otherwise stick while it is merely open. The lock cannot be dropped
/// without dropping the client, so that is what this drops: the surfaces, PTYs
/// and scrollback stay, and only the herdr control clients cycle.
///
/// `HoldPolicy` owns the decision, including the debounce; this owns the timer
/// and the notifications.
@MainActor
final class HerdrHoldCoordinator {
    private let viewModel: SessionViewModel
    private var policy = HoldPolicy()
    private var releaseTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(viewModel: SessionViewModel, notificationCenter: NotificationCenter = .default) {
        self.viewModel = viewModel
        observers = [
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.apply(.becameActive) }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.apply(.resignedActive) }
            },
        ]
    }

    /// No teardown counterpart: one of these is built in `PaddockApp.init` and
    /// held for the process's life, so there is no point at which removing the
    /// observers would run before the app is going away anyway.
    private func apply(_ event: HoldPolicy.Event) {
        switch policy.handle(event) {
        case .none:
            break
        case .scheduleRelease(let delay):
            releaseTimer?.invalidate()
            releaseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.apply(.releaseDeadline) }
            }
        case .cancelScheduledRelease:
            releaseTimer?.invalidate()
            releaseTimer = nil
        case .release:
            releaseTimer = nil
            viewModel.releaseHerdrHold()
        case .take:
            viewModel.takeHerdrHold()
        }
    }
}
