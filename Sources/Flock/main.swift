import Foundation
import FlockCore
import SwiftUI

// A hand-written entry point, not `@main` on `FlockApp`: `--bridge` and the
// `flock` shell command must run fully headless (no NSApplication) before
// anything SwiftUI touches the window server, which `FlockApp.main()` (App's
// own entry point) does the moment it is called. `CommandLine.arguments` is
// checked first instead.
let bridgeArguments = Array(CommandLine.arguments.dropFirst())
let invokedAs = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
if bridgeArguments.contains("--bridge") {
    ControlBridge.run(arguments: bridgeArguments)
} else if let command = FlockCommand.parse(invokedAs: invokedAs, arguments: bridgeArguments) {
    let name = FlockCommand.linkNames.contains(invokedAs)
        ? invokedAs
        : CommandLineTool.name(bundleID: Bundle.main.bundleIdentifier)
    FlockCommandLine.run(command, name: name)
} else {
    FlockApp.main()
}
