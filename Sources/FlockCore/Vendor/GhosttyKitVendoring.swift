import GhosttyKit

/// Referencing (never calling) the vendored xcframework's entry point makes a
/// broken vendoring step (missing header, wrong module name, stale artifact)
/// fail the build here instead of surfacing later at the first renderer call.
public enum GhosttyKitVendoring {
    public static let entryPoint: @convention(c) (UInt, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 = ghostty_init
}
