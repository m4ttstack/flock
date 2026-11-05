import Foundation

/// Whether a herdr binary's bytes carry the mouse verbs the patch adds
/// (`terminal.mouse` inbound, `terminal.mouse_capture` outbound). This is the
/// marker flock checks for install detection: read the binary, never run it,
/// since running an unknown herdr build to interrogate it is both slower and
/// riskier than inspecting it.
public enum HerdrMouseVerbs {
    /// The outbound verb, never the inbound one: stock herdr 0.9.2 accepts
    /// `terminal.mouse` but never reports capture, and flock needs both.
    public static let marker = "terminal.mouse_capture"

    /// An x86_64 build writes the verb as 8-byte immediates ("terminal",
    /// ".mouse_c", "apture"), so it never holds the whole string. The middle
    /// chunk is absent from stock herdr 0.9.5 on x86_64.
    public static let x86_64Marker = ".mouse_c"

    public static func present(in data: Data) -> Bool {
        let markers = switch MachOArch.of(data) {
        case .x86_64: [x86_64Marker]
        case .arm64: [marker]
        case nil: [marker, x86_64Marker]
        }
        return markers.contains { data.range(of: Data($0.utf8)) != nil }
    }
}

/// The CPU a thin 64-bit Mach-O is built for, read from its header.
enum MachOArch {
    case arm64
    case x86_64

    static func of(_ data: Data) -> MachOArch? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data.prefix(8))
        guard bytes[0..<4] == [0xCF, 0xFA, 0xED, 0xFE] else { return nil }
        let cpuType = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        switch cpuType {
        case 0x0100_000C: return .arm64
        case 0x0100_0007: return .x86_64
        default: return nil
        }
    }
}
