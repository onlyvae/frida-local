import Foundation

struct TargetInventoryEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let pid: Int?
    let bundleID: String?
    let thirdParty: Bool?
    let iconBundleID: String?
    let iconBundlePath: String?

    var isThirdParty: Bool { thirdParty == true }

    var detail: String {
        if let pid { return "PID \(pid)" }
        return bundleID ?? ""
    }
}

private struct TargetInventory: Decodable {
    let targets: [TargetInventoryEntry]
}

enum ListenAddress: String, Decodable {
    case loopback = "127.0.0.1"
    case allInterfaces = "0.0.0.0"
}

struct ServerStatus: Decodable {
    var running = false
    var port = 27042
    var address: ListenAddress = .loopback
    var version = ""
    var installedVersions = [String]()
    var sessionPID: Int?
    var sessionName: String?
    var serverError: String?
}

struct LogEntry: Decodable, Identifiable {
    let id: Int
    let kind: String
    let text: String
}

struct ConsoleUpdate: Decodable {
    let epoch: String
    let status: ServerStatus
    let entries: [LogEntry]
}

struct ReleaseDownloadProgress: Decodable, Equatable {
    let receivedBytes: Int64
    let totalBytes: Int64
    let validating: Bool

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

@MainActor
final class ServiceClient: ObservableObject {
    @Published private(set) var status = ServerStatus()
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var connectionError: String?
    @Published var operationError: String?
    @Published private(set) var pendingVersion: String?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: ReleaseDownloadProgress?

    private var connections: [Int: NSXPCConnection] = [:]
    private var currentMajor = 17
    private var epoch: String?
    private var cursor = 0
    private var polling = false
    private var revision = 0

    private typealias Reply = @Sendable (Data?, String?) -> Void
    private typealias Operation = (LocalFridaService, @escaping Reply) -> Void

    func poll() async {
        guard !busy, !polling else { return }
        polling = true
        defer { polling = false }
        let expectedRevision = revision
        do {
            try await updateConsole(revision: expectedRevision)
        } catch {
            guard expectedRevision == revision else { return }
            connected = false
            connectionError = error.localizedDescription
        }
    }

    func startServer() async { await operate { $0.startServer(reply: $1) } }
    func stopServer() async { await operate { $0.stopServer(reply: $1) } }
    func setListener(address: ListenAddress, port: Int) async {
        await operate { $0.updateAddress(address.rawValue, port: port, reply: $1) }
    }
    func stopSession() async { await operate { $0.stopSession(reply: $1) } }

    func listTargets(spawn: Bool) async throws -> [TargetInventoryEntry] {
        let data = try await request(to: currentMajor) { $0.listTargets(spawn: spawn, reply: $1) }
        let inventory = try JSONDecoder().decode(TargetInventory.self, from: data)
        return inventory.targets.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func run(_ script: LocalScript, bundleID: String?, pid: Int, spawn: Bool) async -> Bool {
        await operate { proxy, reply in
            proxy.runScript(script.source, name: script.name, bundle: bundleID, pid: pid, spawn: spawn, reply: reply)
        }
    }

    @discardableResult
    func downloadVersion(_ release: FridaRelease) async -> Bool {
        guard !busy, connected, release.supported, let destination = release.major else { return false }
        if status.installedVersions.contains(release.version) { return true }
        guard status.sessionPID == nil else {
            operationError = "请先停止当前会话。"
            return false
        }

        busy = true
        revision += 1
        pendingVersion = release.version
        isDownloading = true
        let tracker = Task { await pollDownload(release.version, on: destination) }
        defer {
            tracker.cancel()
            isDownloading = false
            downloadProgress = nil
            pendingVersion = nil
            busy = false
        }
        do {
            _ = try await request(to: destination) {
                $0.installVersion(release.version, checksum: release.sha256, reply: $1)
            }
            try await updateConsole()
            return status.installedVersions.contains(release.version)
        } catch {
            operationError = error.localizedDescription
            try? await updateConsole()
            return false
        }
    }

    @discardableResult
    func selectVersion(_ release: FridaRelease) async -> Bool {
        guard !busy, connected, release.supported, let destination = release.major else { return false }
        if status.version == release.version { return true }
        guard status.installedVersions.contains(release.version) else {
            operationError = "请先下载这个版本。"
            return false
        }
        guard status.sessionPID == nil else {
            operationError = "请先停止当前会话。"
            return false
        }

        busy = true
        revision += 1
        pendingVersion = release.version
        defer { busy = false; pendingVersion = nil }
        let previous = status
        let previousMajor = currentMajor
        var stopped = false
        do {
            if previous.running {
                _ = try await request(to: previousMajor) { $0.stopForVersionChange(reply: $1) }
                stopped = true
            }
            let data = try await request(to: destination) {
                $0.selectVersion(release.version, replacing: previous.version, restart: previous.running, reply: $1)
            }
            status = try JSONDecoder().decode(ServerStatus.self, from: data)
            currentMajor = destination
            try await updateConsole()
            return true
        } catch {
            let failure = error.localizedDescription
            if stopped {
                try? await updateConsole()
                if status.version == previous.version {
                    do {
                        _ = try await request(to: previousMajor) { $0.startServer(reply: $1) }
                    } catch {
                        operationError = failure + " 恢复原服务失败。" + error.localizedDescription
                    }
                } else if status.version == release.version {
                    return true
                }
            }
            if operationError == nil { operationError = failure }
            try? await updateConsole()
            return false
        }
    }

    private func pollDownload(_ version: String, on major: Int) async {
        while !Task.isCancelled {
            if let data = try? await request(to: major, { $0.downloadProgress(for: version, reply: $1) }),
               !Task.isCancelled,
               let snapshot = try? JSONDecoder().decode(ReleaseDownloadProgress.self, from: data),
               snapshot != downloadProgress {
                downloadProgress = snapshot
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func clearLogs() { logs = [] }

    @discardableResult
    private func operate(_ operation: Operation) async -> Bool {
        guard !busy else { return false }
        busy = true
        revision += 1
        defer { busy = false }
        do {
            let data = try await request(operation)
            status = try JSONDecoder().decode(ServerStatus.self, from: data)
            try await updateConsole()
            return true
        } catch {
            operationError = error.localizedDescription
            do { try await updateConsole() } catch {
                connected = false
                connectionError = error.localizedDescription
            }
            return false
        }
    }

    private func updateConsole(revision expected: Int? = nil) async throws {
        var data = try await request { $0.console(after: cursor, reply: $1) }
        guard expected == nil || expected == revision else { return }
        var update = try JSONDecoder().decode(ConsoleUpdate.self, from: data)
        if let major = FridaRelease.components(of: update.status.version)?.first, major != currentMajor {
            data = try await request(to: major) { $0.console(after: 0, reply: $1) }
            guard expected == nil || expected == revision else { return }
            update = try JSONDecoder().decode(ConsoleUpdate.self, from: data)
            currentMajor = major
        }
        if epoch != update.epoch {
            if epoch != nil {
                cursor = 0
                logs = []
            }
            epoch = update.epoch
        }
        status = update.status
        logs.append(contentsOf: update.entries.filter { $0.id > cursor })
        if let last = logs.last { cursor = last.id }
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        connected = true
        connectionError = nil
    }

    private func request(to major: Int? = nil, _ operation: Operation) async throws -> Data {
        guard let connection = activeConnection(for: major ?? currentMajor) else { throw ServiceError(message: "无法连接本机服务管理器。") }
        return try await withCheckedThrowingContinuation { continuation in
            let object = connection.remoteObjectProxyWithErrorHandler { error in
                let failure: Error? = error
                continuation.resume(throwing: failure ?? ServiceError(message: "本机服务连接已断开。"))
            }
            let proxy = unsafeBitCast(object as AnyObject, to: LocalFridaService.self)
            operation(proxy) { data, message in
                if let message {
                    continuation.resume(throwing: ServiceError(message: message))
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ServiceError(message: "服务管理器返回了空响应。"))
                }
            }
        }
    }

    private func activeConnection(for major: Int) -> NSXPCConnection? {
        if let connection = connections[major] { return connection }
        guard let next = FLCreateServiceConnection(major) else { return nil }
        next.remoteObjectInterface = NSXPCInterface(with: LocalFridaService.self)
        next.invalidationHandler = { [weak self, weak next] in
            Task { @MainActor in
                guard self?.connections[major] === next else { return }
                self?.connections[major] = nil
            }
        }
        next.resume()
        connections[major] = next
        return next
    }
}

private struct ServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
