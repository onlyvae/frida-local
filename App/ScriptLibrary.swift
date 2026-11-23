import Foundation

struct LocalScript: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let source: String
    let importedAt: Date
}

@MainActor
final class ScriptLibrary: ObservableObject {
    static let maximumScriptSize = 512 * 1024
    @Published private(set) var scripts: [LocalScript] = []
    @Published private(set) var loadError: String?
    private let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FridaLocal/Scripts", isDirectory: true)
        do { try reload() } catch { loadError = error.localizedDescription }
    }

    func importFile(_ url: URL) throws -> LocalScript {
        guard url.pathExtension.lowercased() == "js" else { throw ScriptError.invalidExtension }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        var readResult: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { item in
            readResult = Result {
                let file = try FileHandle(forReadingFrom: item)
                defer { try? file.close() }
                return try file.read(upToCount: Self.maximumScriptSize + 1) ?? Data()
            }
        }
        if let coordinationError { throw coordinationError }
        guard let readResult else { throw ScriptError.readFailed }
        let data = try readResult.get()
        guard data.count <= Self.maximumScriptSize else { throw ScriptError.tooLarge }
        guard let source = String(data: data, encoding: .utf8),
              !source.contains("\0"), !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptError.invalidSource
        }
        let script = LocalScript(id: UUID(), name: url.lastPathComponent, source: source, importedAt: Date())
        try save(script)
        return script
    }

    func filzaURL(for script: LocalScript) throws -> URL {
        let filename = script.name.lowercased().hasSuffix(".js") ? script.name : "\(script.name).js"
        let safeName = filename.contains("/") || filename.contains("\0") || filename.utf8.count > 255
            ? "Script.js" : filename
        let folder = viewingFolder(for: script.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(safeName)
        try Data(script.source.utf8).write(to: file, options: .atomic)

        var link = URLComponents()
        link.scheme = "filza"
        link.host = "view"
        link.path = file.resolvingSymlinksInPath().path
        guard let url = link.url else { throw ScriptError.invalidViewingLink }
        return url
    }

    func delete(_ script: LocalScript) throws {
        try FileManager.default.removeItem(at: location(of: script.id))
        scripts.removeAll { $0.id == script.id }
        try? FileManager.default.removeItem(at: viewingFolder(for: script.id))
    }

    private func reload() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var loaded: [LocalScript] = []
        var unreadable = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
            do {
                loaded.append(try JSONDecoder().decode(LocalScript.self, from: Data(contentsOf: url)))
            } catch {
                unreadable += 1
            }
        }
        scripts = loaded.sorted { $0.importedAt > $1.importedAt }
        if unreadable > 0 { loadError = "有 \(unreadable) 个脚本记录无法读取。" }
    }

    private func save(_ script: LocalScript) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(script).write(to: location(of: script.id), options: .atomic)
        scripts.insert(script, at: 0)
    }

    private func viewingFolder(for id: UUID) -> URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent("ScriptFiles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func location(of id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}

private enum ScriptError: LocalizedError {
    case invalidExtension, readFailed, tooLarge, invalidSource, invalidViewingLink

    var errorDescription: String? {
        switch self {
        case .invalidExtension: return "请选择 .js 文件。"
        case .readFailed: return "无法读取脚本。"
        case .tooLarge: return "单个脚本最大为 512 KB。"
        case .invalidSource: return "脚本必须是非空的 UTF-8 文本。"
        case .invalidViewingLink: return "无法生成在 Filza 中查看脚本的链接。"
        }
    }
}
