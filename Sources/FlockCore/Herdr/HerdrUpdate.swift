import Foundation

public enum HerdrVersionOrder {
    /// nil when either side is not dotted integers.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool? {
        guard let a = components(candidate), let b = components(installed) else { return nil }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
    }
}

public enum HerdrLatestManifest {
    public static let url = URL(string: "https://herdr.dev/latest.json")!

    /// `version` from herdr.dev/latest.json; nil for anything else.
    public static func version(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, HerdrVersionOrder.isNewer(version, than: "0") != nil else {
            return nil
        }
        return version
    }
}

public enum HerdrInstallKind {
    /// `herdr update` refuses to run on a Homebrew install.
    public static func isHomebrew(resolvedPath: String) -> Bool {
        resolvedPath.contains("/Cellar/")
    }
}

public enum HerdrUpdateNotice: Equatable, Sendable {
    case available(latest: String, installed: String, command: String, reinstallAfter: Bool)
    case breaksMouse(latest: String, installed: String, command: String)

    public static func decide(
        installed: String?, latest: String?, patchInstalled: Bool, catalogHasLatest: Bool, homebrew: Bool
    ) -> HerdrUpdateNotice? {
        guard let installed, let latest, HerdrVersionOrder.isNewer(latest, than: installed) == true else { return nil }
        let command = homebrew ? "brew upgrade herdr" : "herdr update --handoff"
        if patchInstalled, !catalogHasLatest {
            return .breaksMouse(latest: latest, installed: installed, command: command)
        }
        return .available(latest: latest, installed: installed, command: command, reinstallAfter: patchInstalled)
    }

    public var isWarning: Bool {
        if case .breaksMouse = self { return true }
        return false
    }

    public var command: String {
        switch self {
        case .available(_, _, let command, _), .breaksMouse(_, _, let command): command
        }
    }
}

public enum HerdrUpdateCopy {
    public static let handoffLead = "Update without closing your panes:"
    public static let warningLead = "If you update anyway:"

    public static func headline(_ notice: HerdrUpdateNotice) -> String {
        switch notice {
        case .available(let latest, let installed, _, _): "herdr \(latest) is available (you have \(installed))"
        case .breaksMouse(let latest, _, _): "Updating herdr to \(latest) will turn off mouse support in flock"
        }
    }

    public static func detail(_ notice: HerdrUpdateNotice) -> String? {
        switch notice {
        case .available(_, _, _, let reinstall):
            reinstall ? "Updating removes the mouse patch; reinstall it here afterwards." : nil
        case .breaksMouse(let latest, _, _):
            "flock doesn't have a mouse patch for \(latest) yet. Mouse clicks and scrolling in panes stop working until a flock update adds one."
        }
    }

    public static func pillTitle(_ notice: HerdrUpdateNotice) -> String {
        switch notice {
        case .available(let latest, _, _, _), .breaksMouse(let latest, _, _): "herdr \(latest)"
        }
    }
}
