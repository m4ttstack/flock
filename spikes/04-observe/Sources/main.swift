import SwiftTerm
import Foundation

// Spike 04: bridge herdr's `terminal session observe` NDJSON stream into a
// headless SwiftTerm Terminal, at 1/10/30 pane scale, plus a backfill probe.
// Modes: bridge | scale | backfill. See FINDINGS.md for what each measures.

final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

func makeTerminal(cols: Int32, rows: Int32) -> Terminal {
    Terminal(delegate: NullTerminalDelegate(), options: TerminalOptions(cols: Int(cols), rows: Int(rows)))
}

// full frames are a from-scratch repaint (absolute cursor addressing), not a
// diff against prior terminal state, so any stale cells outside what the new
// frame touches would survive without an explicit reset first.
func feed(_ term: Terminal, frame: [String: Any]) {
    guard let b64 = frame["bytes"] as? String, let data = Data(base64Encoded: b64) else { return }
    if frame["full"] as? Bool == true {
        term.resetToInitialState()
    }
    term.feed(byteArray: [UInt8](data))
}

func screenText(_ term: Terminal) -> String {
    (0..<term.rows).compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
}

// Style-survival probe: reports the fg color attribute of column 0 on every
// row, to confirm SGR colors from a backfilled `pane.read` carry through as
// real cell attributes and not just plain text.
func rowColors(_ term: Terminal) -> [String] {
    (0..<term.rows).map { row -> String in
        guard let line = term.getLine(row: row) else { return "?" }
        let cell = line[0]
        switch cell.attribute.fg {
        case .ansi256(let code): return "ansi256(\(code))"
        case .trueColor(let r, let g, let b): return "trueColor(\(r),\(g),\(b))"
        case .defaultColor: return "default"
        case .defaultInvertedColor: return "inverted"
        }
    }
}

func eprint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func stdoutLine(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

// MARK: - NDJSON line reader over a child process's stdout pipe

final class ObserveChild {
    let process: Process
    let term: Terminal
    let pane: String
    private let pipe = Pipe()
    private var buffer = Data()
    var frameCount = 0
    var closed = false

    init(herdrPath: String, socket: String, pane: String, cols: Int32 = 80, rows: Int32 = 24) {
        self.pane = pane
        self.term = makeTerminal(cols: cols, rows: rows)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: herdrPath)
        p.arguments = ["terminal", "session", "observe", pane, "--cols", "\(cols)", "--rows", "\(rows)"]
        var env = ProcessInfo.processInfo.environment
        env["HERDR_SOCKET_PATH"] = socket
        p.environment = env
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        self.process = p
    }

    func start() throws {
        try process.run()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let chunk = fh.availableData
            if chunk.isEmpty {
                self.closed = true
                return
            }
            self.buffer.append(chunk)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                if lineData.isEmpty { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                if obj["type"] as? String == "terminal.frame" {
                    feed(self.term, frame: obj)
                    self.frameCount += 1
                } else if obj["type"] as? String == "terminal.closed" {
                    self.closed = true
                }
            }
        }
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        process.terminate()
    }
}

func runHerdrCLI(herdrPath: String, socket: String, args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: herdrPath)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["HERDR_SOCKET_PATH"] = socket
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - modes

let args = CommandLine.arguments
guard args.count >= 2 else {
    eprint("usage: FlockObserveSpike <bridge|scale|backfill> ...")
    exit(2)
}
let herdrPath = ProcessInfo.processInfo.environment["HERDR_BIN"] ?? "/Users/matt/.local/bin/herdr"

switch args[1] {
case "bridge":
    // bridge <socket> <pane_id> <seconds> [cols] [rows]
    guard args.count >= 5 else { eprint("usage: bridge <socket> <pane_id> <seconds> [cols] [rows]"); exit(2) }
    let socket = args[2], pane = args[3], seconds = Double(args[4]) ?? 3.0
    let cols = args.count >= 6 ? (Int32(args[5]) ?? 80) : 80
    let rows = args.count >= 7 ? (Int32(args[6]) ?? 24) : 24
    let child = ObserveChild(herdrPath: herdrPath, socket: socket, pane: pane, cols: cols, rows: rows)
    try child.start()
    stdoutLine("{\"type\":\"started\",\"pid\":\(child.process.processIdentifier)}")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    stdoutLine("FRAME_COUNT \(child.frameCount)")
    stdoutLine("SCREEN_TEXT_BEGIN")
    stdoutLine(screenText(child.term))
    stdoutLine("SCREEN_TEXT_END")
    child.stop()

case "scale":
    // scale <socket> <seconds> <pane_id...>
    guard args.count >= 4 else { eprint("usage: scale <socket> <seconds> <pane_id...>"); exit(2) }
    let socket = args[2], seconds = Double(args[3]) ?? 60.0
    let panes = Array(args[4...])
    var children: [ObserveChild] = []
    for pane in panes {
        let c = ObserveChild(herdrPath: herdrPath, socket: socket, pane: pane)
        try c.start()
        children.append(c)
        stdoutLine("{\"type\":\"child_pid\",\"pane\":\"\(pane)\",\"pid\":\(c.process.processIdentifier)}")
    }
    stdoutLine("{\"type\":\"self_pid\",\"pid\":\(ProcessInfo.processInfo.processIdentifier)}")
    stdoutLine("{\"type\":\"all_started\",\"count\":\(children.count)}")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    for c in children {
        stdoutLine("{\"type\":\"frame_count\",\"pane\":\"\(c.pane)\",\"count\":\(c.frameCount),\"closed\":\(c.closed)}")
        c.stop()
    }

case "backfill":
    // backfill <socket> <pane_id> <lines> [observe_seconds] [cols] [rows]
    guard args.count >= 4 else { eprint("usage: backfill <socket> <pane_id> <lines> [observe_seconds] [cols] [rows]"); exit(2) }
    let socket = args[2], pane = args[3], lines = args[4]
    let observeSeconds = args.count >= 6 ? (Double(args[5]) ?? 2.0) : 2.0
    let cols = args.count >= 7 ? (Int32(args[6]) ?? 80) : 80
    let rows = args.count >= 8 ? (Int32(args[7]) ?? 24) : 24
    let ansi = runHerdrCLI(herdrPath: herdrPath, socket: socket, args: ["pane", "read", pane, "--source", "recent", "--format", "ansi", "--lines", lines])
    let term = makeTerminal(cols: cols, rows: rows)
    term.feed(byteArray: [UInt8](ansi.data(using: .utf8) ?? Data()))
    stdoutLine("BACKFILL_SCREEN_BEGIN")
    stdoutLine(screenText(term))
    stdoutLine("BACKFILL_SCREEN_END")
    stdoutLine("BACKFILL_COLORS " + rowColors(term).joined(separator: "|"))

    // Attach observe live on top of the backfilled terminal (no reset here;
    // this is the seam-quality check: does the first live frame tear the
    // backfilled history, or does it compose cleanly on top of it).
    let child = ObserveChild(herdrPath: herdrPath, socket: socket, pane: pane, cols: cols, rows: rows)
    child.term.feed(byteArray: [UInt8](ansi.data(using: .utf8) ?? Data()))
    try child.start()
    RunLoop.main.run(until: Date().addingTimeInterval(observeSeconds))
    stdoutLine("SEAM_FRAME_COUNT \(child.frameCount)")
    stdoutLine("SEAM_SCREEN_BEGIN")
    stdoutLine(screenText(child.term))
    stdoutLine("SEAM_SCREEN_END")
    child.stop()

default:
    eprint("unknown mode \(args[1])")
    exit(2)
}
