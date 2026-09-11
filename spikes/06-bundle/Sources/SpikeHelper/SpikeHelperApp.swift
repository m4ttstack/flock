import SwiftUI
import Foundation

// One-window helper app. The marker file is the launch proof the harness
// polls for -- writing it in init() means it lands even if the window
// never gets focus (headless launch paths still construct the App).
@main
struct SpikeHelperApp: App {
    init() {
        SpikeHelperApp.writeMarker()
    }

    var body: some Scene {
        WindowGroup {
            Text("Spike Helper Launched").padding().frame(width: 320, height: 160)
        }
    }

    static func writeMarker() {
        let resultDir = "/tmp/paddock-spike-06"
        try? FileManager.default.createDirectory(atPath: resultDir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let ppid = getppid()
        let bundlePath = Bundle.main.bundlePath
        let ts = ISO8601DateFormatter().string(from: Date())
        let path = "\(resultDir)/helper-launched-\(pid).marker"
        let body = """
        pid=\(pid)
        ppid=\(ppid)
        bundlePath=\(bundlePath)
        timestamp=\(ts)
        argv=\(CommandLine.arguments.joined(separator: " "))

        """
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
