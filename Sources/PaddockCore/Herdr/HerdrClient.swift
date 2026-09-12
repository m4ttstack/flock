import Foundation

/// Minimal JSON value for encoding request params without a fixed schema.
public enum JSONValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum HerdrClientError: Error, Sendable {
    case protocolTooOld(found: Int, required: Int)
    case server(code: String, message: String)
    case transport(String)
}

/// Talks to herdr's api socket. AMENDED per spike 2 + source dive: the
/// server answers exactly one request per connection then closes it
/// (identical at v0.8.0 and HEAD; herdr's own ApiClient does
/// connect-per-request). Every request here opens a fresh LineSocket; there
/// is no pooling or multiplexing to build, because the server contract
/// forbids it. Never write on a subscription or pending-wait connection: the
/// server's liveness probe treats any inbound byte on one as a disconnect.
public actor HerdrClient {
    public static let minimumProtocol = 22

    private let socketPath: String
    private var sequence = 0

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func request<P: Encodable & Sendable, R: Decodable & Sendable>(
        _ method: String,
        _ params: P,
        as: R.Type
    ) async throws -> R {
        let line = try await performRequest(method: method, params: params)
        do {
            return try JSONDecoder().decode(ResultEnvelope<R>.self, from: line).result
        } catch let error as HerdrClientError {
            throw error
        } catch {
            throw HerdrClientError.transport("decode failed: \(error)")
        }
    }

    public func requestRaw(_ method: String, _ params: [String: JSONValue]) async throws -> Data {
        try await performRequest(method: method, params: params)
    }

    /// Fetches herdr's own split tree for one tab. Wire-verified against
    /// herdr HEAD (src/app/api/layouts.rs `handle_layout_export` and
    /// src/api/schema/panes.rs `LayoutExportParams`/`LayoutDescription`):
    /// request is `{tab_id}`, response unwraps as `result.layout`.
    public func layoutExport(tabID: TabID) async throws -> ExportedLayoutDescription {
        struct Params: Encodable, Sendable {
            let tabID: String
            enum CodingKeys: String, CodingKey { case tabID = "tab_id" }
        }
        struct Wrapper: Decodable, Sendable {
            let layout: ExportedLayoutDescription
        }
        let wrapper: Wrapper = try await request("layout.export", Params(tabID: tabID.rawValue), as: Wrapper.self)
        return wrapper.layout
    }

    public func verifyProtocol() async throws {
        let result: PingResult = try await request("ping", [String: JSONValue](), as: PingResult.self)
        guard result.protocolVersion >= Self.minimumProtocol else {
            throw HerdrClientError.protocolTooOld(found: result.protocolVersion, required: Self.minimumProtocol)
        }
    }

    private func nextID() -> String {
        sequence += 1
        return "pd:\(ProcessInfo.processInfo.processIdentifier):\(sequence)"
    }

    private func performRequest<P: Encodable & Sendable>(method: String, params: P) async throws -> Data {
        let id = nextID()
        let requestLine = try encodeRequest(id: id, method: method, params: params)
        let socket = try await LineSocket(path: socketPath)
        do {
            let line = try await sendAndAwaitReply(socket: socket, requestLine: requestLine)
            await socket.close()
            return try Self.validate(line: line)
        } catch {
            await socket.close()
            throw error
        }
    }

    private func sendAndAwaitReply(socket: LineSocket, requestLine: Data) async throws -> Data {
        try await socket.send(line: requestLine)
        for try await line in socket.lines {
            return line
        }
        throw HerdrClientError.transport("connection closed before a response arrived")
    }

    private func encodeRequest<P: Encodable>(id: String, method: String, params: P) throws -> Data {
        do {
            return try JSONEncoder().encode(RequestEnvelope(id: id, method: method, params: params))
        } catch {
            throw HerdrClientError.transport("encode failed: \(error)")
        }
    }

    private static func validate(line: Data) throws -> Data {
        let peek: ErrorPeek
        do {
            peek = try JSONDecoder().decode(ErrorPeek.self, from: line)
        } catch {
            throw HerdrClientError.transport("malformed response: \(error)")
        }
        if let error = peek.error {
            throw HerdrClientError.server(code: error.code, message: error.message)
        }
        return line
    }
}

private struct RequestEnvelope<P: Encodable>: Encodable {
    let id: String
    let method: String
    let params: P
}

private struct ResultEnvelope<R: Decodable>: Decodable {
    let result: R
}

private struct ErrorPeek: Decodable {
    struct ErrorPayload: Decodable {
        let code: String
        let message: String
    }
    let error: ErrorPayload?
}

private struct PingResult: Decodable, Sendable {
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
    }
}
