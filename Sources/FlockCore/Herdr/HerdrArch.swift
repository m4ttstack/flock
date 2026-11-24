import Foundation

/// The CPU a herdr build is made for. A build is published per architecture,
/// and the one installed must match the Mac's own CPU.
public enum HerdrArch: String, CaseIterable, Sendable {
    case arm64
    case x86_64

    /// The Mac's CPU, not this process's: a universal Flock opened under
    /// Rosetta on Apple silicon must still install the arm64 herdr.
    public static var current: HerdrArch {
        #if arch(x86_64)
            isTranslated ? .arm64 : .x86_64
        #else
            .arm64
        #endif
    }

    private static var isTranslated: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 && translated == 1
    }
}
