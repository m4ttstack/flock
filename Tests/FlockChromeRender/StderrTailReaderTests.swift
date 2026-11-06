import Foundation
import XCTest

final class StderrTailReaderTests: XCTestCase {
    private func finish(_ reader: StderrTailReader) async -> String? {
        await withCheckedContinuation { continuation in
            reader.finish { continuation.resume(returning: $0) }
        }
    }

    /// The writer stays open, as a ProxyCommand child holding stderr would:
    /// finish must drain what is there without waiting for EOF.
    func testFinishDrainsWhatIsWrittenWithoutWaitingForEOF() async {
        let pipe = Pipe()
        let reader = StderrTailReader(handle: pipe.fileHandleForReading)
        pipe.fileHandleForWriting.write(Data("debug1: connecting\nPermission denied (publickey).\n".utf8))
        let line = await finish(reader)
        XCTAssertEqual(line, "Permission denied (publickey).")
        try? pipe.fileHandleForWriting.close()
    }

    func testFinishAfterEOFStillHasTheLastLine() async throws {
        let pipe = Pipe()
        let reader = StderrTailReader(handle: pipe.fileHandleForReading)
        pipe.fileHandleForWriting.write(Data("Connection closed by remote host\n".utf8))
        try pipe.fileHandleForWriting.close()
        try await Task.sleep(for: .milliseconds(50))
        let line = await finish(reader)
        XCTAssertEqual(line, "Connection closed by remote host")
    }

    func testOnlyTheTailIsKept() async {
        let pipe = Pipe()
        let reader = StderrTailReader(handle: pipe.fileHandleForReading, limit: 64)
        let noise = String(repeating: "x", count: 50) + "\n"
        for _ in 0..<200 { pipe.fileHandleForWriting.write(Data(noise.utf8)) }
        pipe.fileHandleForWriting.write(Data("last reason\n".utf8))
        let line = await finish(reader)
        XCTAssertEqual(line, "last reason")
        try? pipe.fileHandleForWriting.close()
    }

    func testOutputAfterFinishIsIgnoredAndNothingYieldsNil() async {
        let pipe = Pipe()
        let reader = StderrTailReader(handle: pipe.fileHandleForReading)
        let line = await finish(reader)
        XCTAssertNil(line)
        pipe.fileHandleForWriting.write(Data("late\n".utf8))
        try? pipe.fileHandleForWriting.close()
        try? await Task.sleep(for: .milliseconds(20))
    }
}
