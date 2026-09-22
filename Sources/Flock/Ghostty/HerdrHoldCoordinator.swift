import AppKit
import Foundation
import FlockCore

/// Hands flock's panes back to herdr while flock is off screen, and takes
/// them again when it comes back into view.
///
/// herdr sizes a pane to whichever shell client is in front, which is why
/// focusing a Mac terminal repaints its panes to that terminal's size. Flock
/// is not a shell client: it attaches per pane and herdr takes a
/// `direct_attach_resize_lock` that does not follow focus, so flock's sizes
/// would otherwise stick while it is merely open. The lock cannot be dropped
/// without dropping the client, so that is what this drops: the surfaces, PTYs
/// and scrollback stay, and only the herdr control clients cycle.
///
/// Dropping the client also ends the pane's frame stream, so a released pane
/// shows the frame it was last sent for as long as the release lasts. That is
/// why the release turns on whether flock is on screen and not on whether it
/// is frontmost: a window the user can see keeps holding while another app is
/// in front, and only a flock that is hidden, miniaturized, on another Space
/// or fully covered lets go.
///
/// `HoldPolicy` owns the decision, including the debounce; this owns the timer
/// and the notifications.
@MainActor
final class HerdrHoldCoordinator {
    private let release: @MainActor () -> Void
    private let take: @MainActor () -> Void
    private let isOnScreen: @MainActor () -> Bool
    private var policy = HoldPolicy()
    private var releaseTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// The visibility this coordinator last acted on. Without it, an app
    /// switch away from a flock the user can still see would re-assert the
    /// take over every pane's FIFO for nothing.
    private var wasOnScreen = true

    /// The app is counted as on screen while it is ACTIVE regardless of what
    /// AppKit reports about occlusion: no window exists yet when this is first
    /// read from `FlockApp.init`, and a foreground launch would otherwise seed
    /// itself as hidden.
    convenience init(
        viewModel: SessionViewModel,
        notificationCenter: NotificationCenter = .default,
        isOnScreen: @MainActor @escaping () -> Bool = {
            NSApp?.isActive == true || NSApp?.occlusionState.contains(.visible) == true
        }
    ) {
        self.init(
            release: { viewModel.releaseHerdrHold() },
            take: { viewModel.takeHerdrHold() },
            notificationCenter: notificationCenter,
            isOnScreen: isOnScreen
        )
    }

    init(
        release: @MainActor @escaping () -> Void,
        take: @MainActor @escaping () -> Void,
        notificationCenter: NotificationCenter = .default,
        isOnScreen: @MainActor @escaping () -> Bool
    ) {
        self.release = release
        self.take = take
        self.isOnScreen = isOnScreen
        observers = [
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyActivation() }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyVisibility() }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyVisibility() }
            },
        ]
        // `HoldPolicy` starts holding, and an app that launches WITHOUT
        // activating (`open -g`, or a launch the user clicks straight past)
        // never posts `didResignActive`, so nothing would ever tell it to let
        // go. Deferred a turn rather than read here: this runs from
        // `FlockApp.init`, BEFORE AppKit has activated anything or built a
        // window, so a foreground launch reads as off screen too and seeding
        // from it there would arm a release on every single launch.
        DispatchQueue.main.async { [weak self] in
            self?.applyVisibility()
        }
    }

    /// Activation re-asserts the take every time, without consulting
    /// visibility: the assertion is the one repair for a pane whose release
    /// or take was dropped on a full FIFO (see `HoldPolicy`), and AppKit can
    /// report the window as still occluded at the moment the app activates.
    private func applyActivation() {
        wasOnScreen = true
        apply(.becameVisible)
    }

    private func applyVisibility() {
        let onScreen = isOnScreen()
        guard onScreen != wasOnScreen else { return }
        wasOnScreen = onScreen
        apply(onScreen ? .becameVisible : .becameHidden)
    }

    /// No teardown counterpart: one of these is built in `FlockApp.init` and
    /// held for the process's life, so there is no point at which removing the
    /// observers would run before the app is going away anyway.
    private func apply(_ event: HoldPolicy.Event) {
        switch policy.handle(event) {
        case .none:
            break
        case .scheduleRelease(let delay):
            releaseTimer?.invalidate()
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.apply(.releaseDeadline) }
            }
            // `.common`, not the default mode `scheduledTimer` would give it: a
            // release scheduled while the run loop is in a tracking mode would
            // otherwise wait for that mode to end.
            RunLoop.main.add(timer, forMode: .common)
            releaseTimer = timer
        case .cancelScheduledRelease:
            releaseTimer?.invalidate()
            releaseTimer = nil
        case .release:
            releaseTimer = nil
            release()
        case .take:
            take()
        }
    }
}
