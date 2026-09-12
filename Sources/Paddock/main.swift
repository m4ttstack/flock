import Foundation
import PaddockCore
import SwiftUI

// A hand-written entry point, not `@main` on `PaddockApp`: `--bridge` must
// run fully headless (no NSApplication) before anything SwiftUI touches the
// window server, which `PaddockApp.main()` (App's own entry point) does the
// moment it is called. `CommandLine.arguments` is checked first instead.
let bridgeArguments = Array(CommandLine.arguments.dropFirst())
if bridgeArguments.contains("--bridge") {
    ControlBridge.run(arguments: bridgeArguments)
} else {
    PaddockApp.main()
}
