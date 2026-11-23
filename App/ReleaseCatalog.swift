import Foundation

struct FridaRelease: Codable, Identifiable, Hashable {
    var id: String { version }
    var major: Int? { Self.components(of: version)?.first }
    var supported: Bool { major == 16 || major == 17 }

    let version: String
    let downloadURL: URL
    let sha256: String?

    static func components(of version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }),
              numbers.map(String.init).joined(separator: ".") == version else { return nil }
        return numbers
    }
}

@MainActor
final class ReleaseCatalog: ObservableObject {
    static let cacheLimit = 10

    @Published private(set) var latest: [FridaRelease] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var loading = false
    @Published private(set) var hasMore = true
    @Published private(set) var error: String?
    @Published private var older: [FridaRelease] = []

    var releases: [FridaRelease] {
        let recent = Set(latest.map(\.version))
        return latest + older.filter { !recent.contains($0.version) }
    }

    private let major: Int
    private let cacheURL: URL
    private let decoder = JSONDecoder()
    private let repository = URL(string: "https://api.github.com/repos/frida/frida")!
    private var remainingTags: ArraySlice<String>?

    init(major: Int) {
        self.major = major
        cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FridaLocal/FridaReleases\(major).json")
        let seedURL = Bundle.main.url(forResource: "FridaReleases", withExtension: "json")
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? decoder.decode(Cache.self, from: $0) }
        let seed = seedURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? decoder.decode(Cache.self, from: $0) }
        if let initial = cached ?? seed {
            latest = Array(sorted(initial.releases.filter { $0.major == major }).prefix(Self.cacheLimit))
            lastChecked = initial.lastChecked
        }
    }

    func refreshIfNeeded() async {
        if lastChecked.map({ Date().timeIntervalSince($0) > 3600 }) ?? true { await refresh() }
    }

    func refresh() async {
        await fetch {
            let tags = try await self.tags()
            let result = try await self.resolve(tags[...], known: self.releases)
            guard !result.releases.isEmpty else { throw CatalogError.missingAsset }
            let checked = Date()
            try self.save(Cache(releases: result.releases, lastChecked: checked))
            self.latest = result.releases
            self.remainingTags = result.remaining
            self.hasMore = !result.remaining.isEmpty
            self.lastChecked = checked
        }
    }

    func loadMore() async {
        guard hasMore else { return }
        await fetch {
            let unresolved: ArraySlice<String>
            if let remaining = self.remainingTags {
                unresolved = remaining
            } else {
                let tags = try await self.tags()
                if let oldest = self.latest.last?.version, let index = tags.firstIndex(of: oldest) {
                    unresolved = tags.dropFirst(index + 1)
                } else {
                    let existing = Set(self.latest.map(\.version))
                    unresolved = tags.filter { !existing.contains($0) }[...]
                }
            }
            let known = Set(self.older.map(\.version))
            let result = try await self.resolve(unresolved.filter { !known.contains($0) }[...], known: [])
            self.older = self.sorted(self.older + result.releases)
            self.remainingTags = result.remaining
            self.hasMore = !result.remaining.isEmpty
        }
    }

    func find(_ version: String) async {
        guard FridaRelease.components(of: version)?.first == major else { return }
        await fetch {
            let release = try await self.release(version)
            if !self.releases.contains(where: { $0.version == release.version }) {
                self.older = self.sorted(self.older + [release])
            }
        }
    }

    private func fetch(_ action: () async throws -> Void) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            try await action()
        } catch is CancellationError {
            return
        } catch let failure as URLError where failure.code == .cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func tags() async throws -> [String] {
        struct Reference: Decodable { let ref: String }

        let url = repository.appendingPathComponent("git/matching-refs/tags/\(major).")
        let data = try await self.data(from: url)
        return try decoder.decode([Reference].self, from: data)
            .map { String($0.ref.dropFirst("refs/tags/".count)) }
            .filter { FridaRelease.components(of: $0)?.first == major }
            .sorted { descending($0, $1) }
    }

    private func release(_ version: String) async throws -> FridaRelease {
        let url = repository.appendingPathComponent("releases/tags").appendingPathComponent(version)
        let data = try await self.data(from: url)
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard let server = release.server, server.version == version else { throw CatalogError.missingAsset }
        return server
    }

    private func resolve(_ tags: ArraySlice<String>, known: [FridaRelease]) async throws
        -> (releases: [FridaRelease], remaining: ArraySlice<String>) {
        var byVersion: [String: FridaRelease] = [:]
        for release in known { byVersion[release.version] = release }
        var remaining = tags
        var releases: [FridaRelease] = []
        while releases.count < Self.cacheLimit, let version = remaining.popFirst() {
            if let cached = byVersion[version] {
                releases.append(cached)
            } else {
                do { releases.append(try await release(version)) }
                catch CatalogError.missingAsset { continue }
            }
        }
        return (releases, remaining)
    }

    private func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
        switch response.statusCode {
        case 200: return data
        case 403, 429: throw CatalogError.rateLimited
        case 404: throw CatalogError.missingAsset
        default: throw CatalogError.invalidResponse
        }
    }

    private func save(_ catalog: Cache) throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(catalog).write(to: cacheURL, options: .atomic)
    }

    private func sorted(_ releases: [FridaRelease]) -> [FridaRelease] {
        releases.sorted { descending($0.version, $1.version) }
    }

    private func descending(_ first: String, _ second: String) -> Bool {
        first.compare(second, options: .numeric) == .orderedDescending
    }

    private struct Cache: Codable {
        let releases: [FridaRelease]
        let lastChecked: Date?
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }

    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    var server: FridaRelease? {
        guard !draft, !prerelease, FridaRelease.components(of: tag_name) != nil else { return nil }
        let name = "frida_\(tag_name)_iphoneos-arm64.deb"
        guard let asset = assets.first(where: { $0.name == name }),
              asset.browser_download_url.absoluteString ==
                "https://github.com/frida/frida/releases/download/\(tag_name)/\(name)" else { return nil }
        return FridaRelease(version: tag_name, downloadURL: asset.browser_download_url, sha256: asset.digest)
    }
}

private enum CatalogError: LocalizedError {
    case invalidResponse, rateLimited, missingAsset

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub 版本列表暂时无法读取。"
        case .rateLimited: return "GitHub 暂时限制了请求次数，稍后可下拉重试。"
        case .missingAsset: return "GitHub 上没有该版本的 iOS arm64 正式包。"
        }
    }
}
