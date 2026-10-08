import FlockCore
import Observation

enum CswapList {
    static let arguments = ["list", "--json"]
    static let deadline: Duration = .seconds(3)

    /// nil when cswap is not on the resolved PATH, failed, or printed a
    /// listing this build cannot read.
    @Sendable
    static func read() async -> [CswapAccount]? {
        let resolved = await Task.detached(priority: .utility) { () -> (cswap: String, environment: [String: String])? in
            guard let cswap = ToolPath.resolve("cswap") else { return nil }
            return (cswap, ToolPath.childEnvironment())
        }.value
        guard let resolved,
              let result = try? await ToolRunner(binaryPath: resolved.cswap, environment: resolved.environment, deadline: deadline)
                  .run(arguments),
              result.exitCode == 0
        else { return nil }
        return CswapAccountList.parse(result.stdout)
    }
}

/// The accounts a pin's Claude Account menu offers. Context menus are built
/// before they open, so the list is read ahead: at startup and whenever the
/// app becomes active.
@MainActor
@Observable
final class CswapStore {
    /// nil while cswap is not detected, which hides the menu.
    private(set) var accounts: [CswapAccount]?

    @ObservationIgnored private let read: @Sendable () async -> [CswapAccount]?

    init(read: @escaping @Sendable () async -> [CswapAccount]? = CswapList.read, accounts: [CswapAccount]? = nil) {
        self.read = read
        self.accounts = accounts
    }

    /// Startup's read and an activation's can overlap; only the latest lands.
    func refresh() async {
        generation += 1
        let mine = generation
        let result = await read()
        guard mine == generation else { return }
        accounts = result
    }

    @ObservationIgnored private var generation = 0
}
