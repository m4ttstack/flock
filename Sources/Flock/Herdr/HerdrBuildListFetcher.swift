import FlockCore
import Foundation

/// The list is a release asset that 404s until the fork's first build is
/// published; that, like any other failure, reads as no list.
enum HerdrBuildListFetcher {
    static func fetch() async -> HerdrBuildList? {
        var request = URLRequest(url: HerdrBuildList.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return HerdrBuildList.decode(data)
    }
}
