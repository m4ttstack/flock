import AppKit
import ServiceManagement
import Foundation

// Menu-bar-stub stand-in: LSUIElement=true, accessory activation policy, no
// window of its own. Driven by argv rather than a real menu so every launch
// path can be exercised from a script without a manual click; the comparison
// under test is the launch mechanism, not the menu UI.

let resultDir = "/tmp/flock-spike-06"
try? FileManager.default.createDirectory(atPath: resultDir, withIntermediateDirectories: true)

func writeResult(_ name: String, _ dict: [String: Any]) {
    let path = "\(resultDir)/result-\(name).json"
    var withTimestamp = dict
    withTimestamp["timestamp"] = ISO8601DateFormatter().string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: withTimestamp, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

func logErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let args = CommandLine.arguments
guard args.count > 1 else {
    logErr("usage: SpikeHost <nsworkspace|process|smappservice-register|smappservice-unregister|smappservice-status|noop>")
    exit(1)
}

let action = args[1]
let hostBundlePath = Bundle.main.bundlePath
let helperAppPath = "\(hostBundlePath)/Contents/Helpers/SpikeHelper.app"
let helperExecPath = "\(helperAppPath)/Contents/MacOS/SpikeHelper"
let helperBundleID = "com.mattstack.flockspike.helper"

switch action {
case "noop":
    // Proves the host itself launched (used for the host-quarantine check).
    writeResult("noop", ["ok": true, "pid": ProcessInfo.processInfo.processIdentifier])
    exit(0)

case "nsworkspace":
    let url = URL(fileURLWithPath: helperAppPath)
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: config) { runningApp, error in
        if let error = error {
            writeResult("nsworkspace", ["ok": false, "error": "\(error)"])
        } else {
            writeResult("nsworkspace", [
                "ok": true,
                "pid": runningApp?.processIdentifier ?? -1,
                "bundleIdentifier": runningApp?.bundleIdentifier ?? "",
            ])
        }
        exit(0)
    }
    // openApplication's completion runs on the main run loop; give it a
    // bounded window rather than exiting before the callback fires.
    RunLoop.main.run(until: Date().addingTimeInterval(10))
    writeResult("nsworkspace", ["ok": false, "error": "timed out waiting for completion handler"])

case "process":
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: helperExecPath)
    do {
        try proc.run()
        writeResult("process", ["ok": true, "pid": proc.processIdentifier])
    } catch {
        writeResult("process", ["ok": false, "error": "\(error)"])
    }
    exit(0)

case "smappservice-register":
    if #available(macOS 13.0, *) {
        let service = SMAppService.loginItem(identifier: helperBundleID)
        do {
            try service.register()
            writeResult("smappservice-register", ["ok": true, "status": "\(service.status)"])
        } catch {
            writeResult("smappservice-register", ["ok": false, "error": "\(error)"])
        }
    } else {
        writeResult("smappservice-register", ["ok": false, "error": "requires macOS 13+"])
    }
    exit(0)

case "smappservice-unregister":
    if #available(macOS 13.0, *) {
        let service = SMAppService.loginItem(identifier: helperBundleID)
        do {
            try service.unregister()
            writeResult("smappservice-unregister", ["ok": true])
        } catch {
            writeResult("smappservice-unregister", ["ok": false, "error": "\(error)"])
        }
    }
    exit(0)

case "smappservice-status":
    if #available(macOS 13.0, *) {
        let service = SMAppService.loginItem(identifier: helperBundleID)
        writeResult("smappservice-status", ["status": "\(service.status.rawValue)", "statusDescription": "\(service.status)"])
    }
    exit(0)

default:
    logErr("unknown action \(action)")
    exit(1)
}
