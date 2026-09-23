import Foundation
import Observation

/// One pane's find bar. libghostty runs the search and paints the matches;
/// this holds what the bar draws and whether its field owns the keyboard.
///
/// A pane's screen is a repaint of herdr's viewport, so libghostty holds no
/// scrollback of its own: a search covers what the pane shows, and re-runs as
/// herdr's viewport scrolls under it.
@MainActor
@Observable
public final class TerminalSearch {
    public private(set) var isOpen = false
    /// Kept across a close, so reopening offers the last search again.
    public var needle = ""
    public private(set) var total: Int?
    public private(set) var selected: Int?
    /// The field holds the keyboard, or is about to. Raised BEFORE the field
    /// asks for it, so the pane's terminal stands down first
    /// (`TerminalFocusClaim`) instead of taking it straight back.
    public var fieldHasFocus = false
    /// Changes on every request to put the keyboard in the field, including a
    /// repeat Cmd+F while the bar is already open.
    public private(set) var focusRequest = 0

    public init() {}

    /// libghostty's `start_search`. A needle arrives only from
    /// `search_selection`; plain Cmd+F keeps whatever was last searched for.
    public func open(needle: String?) {
        if let needle, !needle.isEmpty {
            self.needle = needle
        }
        isOpen = true
        fieldHasFocus = true
        focusRequest &+= 1
    }

    public func close() {
        isOpen = false
        fieldHasFocus = false
        total = nil
        selected = nil
    }

    /// libghostty reports -1 for "not known yet".
    public func report(total: Int) {
        self.total = total < 0 ? nil : total
    }

    public func report(selected: Int) {
        self.selected = selected < 0 ? nil : selected
    }

    /// "2/5" once a match is selected, "-/5" before, nothing while the count
    /// is unknown or there is no needle.
    public var countLabel: String? {
        guard !needle.isEmpty, let total else { return nil }
        guard let selected else { return "-/\(total)" }
        return "\(selected + 1)/\(total)"
    }

    /// A one or two character needle matches most of a screen, so it waits to
    /// see whether more is typed before libghostty is asked to search for it.
    public static func debounce(for needle: String) -> Duration {
        needle.isEmpty || needle.count >= 3 ? .zero : .milliseconds(300)
    }
}
