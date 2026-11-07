import Darwin
import Foundation

/// Whether the herdr server behind a socket runs the herdr binary on disk. A
/// running process keeps the file it was started from even after a rename
/// replaces it, so the server is on the binary on disk only while that file
/// is still the one its memory maps.
public enum HerdrServerBinary: Equatable, Sendable {
    case onDisk
    case other
    /// The server, or the process behind it, could not be read.
    case unknown

    struct FileID: Equatable {
        let device: Int32
        let inode: UInt64
    }

    /// Connects to `socketPath` to learn the server's pid, then reads which
    /// files that process maps. Blocks for the connect; call it off the main actor.
    public static func probe(socketPath: String, binaryPath: String) -> HerdrServerBinary {
        guard let pid = peerProcess(socketPath: socketPath) else { return .unknown }
        return compare(pid: pid, binaryPath: binaryPath)
    }

    public static func compare(pid: pid_t, binaryPath: String) -> HerdrServerBinary {
        guard let onDisk = fileID(of: URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path) else {
            return .unknown
        }
        return maps(onDisk, pid: pid)
    }

    static func peerProcess(socketPath: String) -> pid_t? {
        guard let fd = try? LineSocket.openAndConnect(path: socketPath) else { return nil }
        defer { Darwin.close(fd) }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    static func fileID(of path: String) -> FileID? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileID(device: info.st_dev, inode: info.st_ino)
    }

    /// Walks the process's memory regions in address order. The cap bounds a
    /// process with an unusual number of mappings; a walk that ends without
    /// meeting the file means the process runs some other binary.
    static func maps(_ file: FileID, pid: pid_t) -> HerdrServerBinary {
        var region = proc_regionwithpathinfo()
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        var address: UInt64 = 0
        for index in 0..<10_000 {
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, size) == size else {
                return index == 0 ? .unknown : .other
            }
            let mapped = region.prp_vip.vip_vi.vi_stat
            if mapped.vst_ino == file.inode, mapped.vst_dev == file.device { return .onDisk }
            let next = region.prp_prinfo.pri_address &+ region.prp_prinfo.pri_size
            guard next > address else { return .other }
            address = next
        }
        return .other
    }
}
