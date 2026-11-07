import AppKit
import FlockCore
import SwiftUI

/// What a machine folder pick needs: Finder only offers this Mac's folders.
struct MachineFolderPick {
    let lister: MachineFolderLister
    /// Folders the machine's panes are in now.
    let suggestions: [String]
    let theme: Theme
}

/// Browses a herdr machine's folders over ssh: the panes' folders first for
/// one click, then the listed folder's subfolders. A path can be typed or
/// pasted into the field too.
struct MachineFolderSheet: View {
    let theme: Theme
    let message: String
    let suggestions: [String]
    let browser: MachineFolderBrowser
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    @State private var typed = ""

    static let size = CGSize(width: 460, height: 440)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(theme.rule).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !suggestions.isEmpty {
                        sectionLabel("Your panes are in")
                        ForEach(suggestions, id: \.self) { folder in
                            FolderRow(theme: theme, symbol: "terminal", title: folder, truncation: .middle) {
                                Task { await browser.go(to: folder) }
                            }
                        }
                        sectionLabel(browser.listing.map { ($0.path as NSString).lastPathComponent }.map { $0.isEmpty ? "/" : $0 } ?? "Folders")
                    }
                    listing
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
            Rectangle().fill(theme.rule).frame(height: 1)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(theme.chrome)
        .onChange(of: browser.requested, initial: true) { _, requested in
            typed = requested ?? ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textStrong)
            HStack(spacing: 6) {
                Button {
                    Task { await browser.goUp() }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.bordered)
                .disabled(browser.listing.flatMap { MachineFolderListing.parent(of: $0.path) } == nil)
                .help("Enclosing folder")
                Button {
                    Task { await browser.go(to: nil) }
                } label: {
                    Image(systemName: "house")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.bordered)
                .help("Home folder")
                TextField("/Users/you/code", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        guard let folder = PinFolders.machineFolder(typed) else { return }
                        Task { await browser.go(to: folder) }
                    }
            }
        }
        .padding(14)
    }

    @ViewBuilder private var listing: some View {
        switch browser.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Listing folders\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        case .failed(let detail):
            VStack(alignment: .leading, spacing: 8) {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Go to Home Folder") { Task { await browser.go(to: nil) } }
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        case .listed:
            if let listing = browser.listing, !listing.subfolders.isEmpty {
                ForEach(listing.subfolders, id: \.self) { name in
                    FolderRow(theme: theme, symbol: "folder", title: name, truncation: .tail, showsChevron: true) {
                        Task { await browser.open(name) }
                    }
                }
            } else {
                Text("No folders inside.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textDim)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(browser.chosen ?? " ")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Choose") {
                if let chosen = browser.chosen { onChoose(chosen) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(browser.chosen == nil)
        }
        .padding(14)
    }
}

private struct FolderRow: View {
    let theme: Theme
    let symbol: String
    let title: String
    let truncation: Text.TruncationMode
    var showsChevron = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textStrong)
                    .lineLimit(1)
                    .truncationMode(truncation)
                Spacer(minLength: 4)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: ChromeRadius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Runs the sheet on the key window, or as a panel of its own without one.
@MainActor
enum MachineFolderPanel {
    static func choose(
        current: String?, message: String, pick: MachineFolderPick, completion: @escaping (String?) -> Void
    ) {
        let browser = MachineFolderBrowser { path in try await pick.lister.list(path) }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: MachineFolderSheet.size),
            styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false
        )
        let host = NSApp.keyWindow
        var finished = false
        let finish: (String?) -> Void = { folder in
            guard !finished else { return }
            finished = true
            if let host, panel.sheetParent != nil { host.endSheet(panel) } else { panel.orderOut(nil) }
            completion(folder)
        }
        panel.contentView = NSHostingView(rootView: MachineFolderSheet(
            theme: pick.theme, message: message, suggestions: pick.suggestions, browser: browser,
            onChoose: { finish($0) }, onCancel: { finish(nil) }
        ))
        if let host {
            host.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
        let start = current.flatMap(PinFolders.machineFolder)
        Task { await browser.go(to: start) }
    }
}
