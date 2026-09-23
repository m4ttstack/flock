import AppKit
import Foundation
import Observation

/// Which flavor this process is: the release Flock, or Flock Dev built by
/// `Scripts/dev-build.sh` (`FlockDevBuild` in its Info.plist).
enum BuildFlavor {
    static let isDev = Bundle.main.object(forInfoDictionaryKey: "FlockDevBuild") as? Bool ?? false

    /// What `Scripts/dev-build.sh` stamped into this build; nil for any build
    /// it did not make, which is what keeps the restart offer out of them.
    static let runningStamp = stamp(in: Bundle.main.infoDictionary)

    static func stamp(in info: [String: Any]?) -> String? {
        guard let stamp = info?["FlockBuildStamp"] as? String, !stamp.isEmpty, !stamp.hasPrefix("$(") else { return nil }
        return stamp
    }

    /// Read fresh from disk rather than through `Bundle`, which caches the
    /// Info.plist it launched with.
    static func stamp(atBundle url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return stamp(in: info)
    }
}

/// Notices a newer Flock Dev build landing where this one was launched from,
/// and relaunches into it on request.
///
/// `Scripts/dev-build.sh` swaps the new bundle into place with a rename, so
/// the directory holding it changes exactly once per build and a stamp read
/// after that change is always a whole bundle's.
@MainActor
@Observable
final class DevBuildWatcher {
    private(set) var newerBuildReady = false

    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored private let runningStamp: String?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?

    init(bundleURL: URL = Bundle.main.bundleURL, runningStamp: String? = BuildFlavor.runningStamp) {
        self.bundleURL = bundleURL
        self.runningStamp = runningStamp
    }

    func start() {
        guard runningStamp != nil, source == nil else { return }
        let directory = bundleURL.deletingLastPathComponent().path
        let descriptor = open(directory, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .link], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        check()
    }

    func check() {
        guard let runningStamp, let onDisk = BuildFlavor.stamp(atBundle: bundleURL) else { return }
        let ready = onDisk != runningStamp
        if ready != newerBuildReady { newerBuildReady = ready }
    }

    /// Quits, then opens the bundle again once this process has exited. The
    /// hand-off is a shell that outlives the app; it gives up after thirty
    /// seconds, so a quit that gets cancelled never reopens anything later.
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        i=0; while kill -0 \(pid) 2>/dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
        kill -0 \(pid) 2>/dev/null || /usr/bin/open "$0"
        """
        let handOff = Process()
        handOff.executableURL = URL(fileURLWithPath: "/bin/sh")
        handOff.arguments = ["-c", script, bundleURL.path]
        do {
            try handOff.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
