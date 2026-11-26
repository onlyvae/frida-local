#if FL_DEVICE_SMOKE
import SwiftUI
import Combine
import Darwin

@main
struct DeviceSmokeEntry {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if let mode = arguments.first(where: { ["--device-smoke", "--catalog-smoke", "--listener-smoke", "--targets-smoke"].contains($0) }) {
            Task {
                let service = ServiceClient()
                let passed: Bool
                switch mode {
                case "--catalog-smoke": passed = await runCatalogSmoke(service: service)
                case "--listener-smoke": passed = await runListenerSmoke(service: service)
                case "--targets-smoke": passed = await runTargetsSmoke(service: service)
                default: passed = await runDeviceSmoke(library: ScriptLibrary(), service: service, headless: true)
                }
                exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            dispatchMain()
        }
        FridaLocalApp.main()
    }
}

@MainActor
@discardableResult
func runDeviceSmoke(library: ScriptLibrary, service: ServiceClient, headless: Bool = false) async -> Bool {
    let request = URL(fileURLWithPath: "/var/mobile/fridalocal-smoke.request")
    let result = URL(fileURLWithPath: "/var/mobile/fridalocal-smoke.result")
    if !headless {
        guard FileManager.default.fileExists(atPath: request.path) else { return false }
        try? FileManager.default.removeItem(at: request)
    }
    var lines: [String] = []
    var sample: LocalScript?
    var original: ServerStatus?
    let backgroundTask = headless ? .invalid : UIApplication.shared.beginBackgroundTask(withName: "Frida Local smoke test")
    defer { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) } }

    func record(_ line: String) {
        lines.append(line)
        if headless {
            print(line)
            fflush(stdout)
        } else {
            try? (lines.joined(separator: "\n") + "\n").write(to: result, atomically: true, encoding: .utf8)
        }
    }

    func require(_ condition: Bool, _ message: String, expectedError: Bool = false) throws {
        let error = service.operationError ?? service.connectionError ?? ""
        service.operationError = nil
        guard condition else { throw DeviceSmokeError.failed(message + (error.isEmpty ? "" : " · " + error)) }
        record("PASS " + message + (expectedError && !error.isEmpty ? " · " + error : ""))
    }

    do {
        record("RUN Frida Local on-device smoke test")
        for _ in 0..<5 {
            await service.poll()
            if service.connected { break }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        try require(service.connected, "App → Mach XPC service")
        if headless {
            try require(service.status.running, "frida-server started during package installation")
        }
        original = service.status
        await service.stopServer()
        try require(!service.status.running, "stop server before changing settings")
        guard let url = Bundle.main.url(forResource: "hello", withExtension: "js") else {
            throw DeviceSmokeError.failed("sample missing")
        }
        let script = try library.importFile(url)
        sample = script
        let coldLibrary = ScriptLibrary()
        try require(coldLibrary.scripts.contains(script), "import and reload script from disk")
        await service.setListener(address: .loopback, port: service.status.port)
        await service.startServer()
        try require(service.status.running, "authenticated frida-server on loopback")

        let ran = await service.run(script, bundleID: nil, pid: 0, spawn: false)
        try require(!ran && service.status.sessionPID == nil && service.operationError == "Attach 模式需要 PID 或 Bundle ID。",
                    "reject an attach request without PID or bundle before creating a session", expectedError: true)

        try library.delete(script)
        sample = nil
        try require(!ScriptLibrary().scripts.contains(where: { $0.id == script.id }), "delete script from disk")
    } catch {
        record("FAIL \(error)")
    }

    if let sample { try? library.delete(sample) }
    if let original {
        await service.stopServer()
        await service.setListener(address: original.address, port: original.port)
        record(service.status.running ? "FAIL service still running" : "PASS stop server")
        if original.running {
            await service.startServer()
            record(service.status.running ? "PASS restore running server" : "FAIL restore running server")
        }
    }
    record("DONE")
    return !lines.contains { $0.hasPrefix("FAIL ") }
}

@MainActor
private func runTargetsSmoke(service: ServiceClient) async -> Bool {
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw DeviceSmokeError.failed(message) }
        print("PASS " + message)
        fflush(stdout)
    }

    let library = ScriptLibrary()
    var imported: LocalScript?
    var started = false
    var originallyRunning = false
    var passed = false
    do {
        guard let example = Bundle.main.url(forResource: "hello", withExtension: "js") else {
            throw DeviceSmokeError.failed("sample missing")
        }
        let script = try library.importFile(example)
        imported = script
        let highlighted = JavaScriptHighlighting.attributedSource(script.source)
        try require(highlighted.string == script.source, "highlighting preserves the imported source")
        try library.delete(script)
        imported = nil

        await service.poll()
        originallyRunning = service.status.running
        if originallyRunning { await service.stopServer() }
        try require(service.connected && !service.status.running, "connect to the idle management service")
        let idleProcesses = try await service.listTargets(spawn: false)
        try require(!idleProcesses.isEmpty && idleProcesses.allSatisfy { $0.pid != nil },
                    "browse running processes while stopped (\(idleProcesses.count) entries)")
        let idleApps = try await service.listTargets(spawn: true)
        try require(!idleApps.isEmpty && idleApps.allSatisfy { $0.bundleID != nil },
                    "browse installed apps while stopped (\(idleApps.count) entries)")
        func checkThirdParty(apps: [TargetInventoryEntry], processes: [TargetInventoryEntry]) throws {
            let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
            try require(apps.contains { $0.bundleID == "dev.fridalocal.app" && $0.isThirdParty }
                        && apps.contains { $0.bundleID?.hasPrefix("com.apple.") == true && !$0.isThirdParty }
                        && apps.allSatisfy { $0.thirdParty != nil },
                        "classify third-party Roothide apps and system apps")
            try require(processes.contains { $0.pid == ownPID && $0.isThirdParty }
                        && processes.contains { $0.pid == 1 && !$0.isThirdParty }
                        && processes.allSatisfy { $0.thirdParty != nil },
                        "classify running app processes and system processes")
            try require(processes.first { $0.pid == ownPID }?.iconBundleID == "dev.fridalocal.app"
                        && processes.first { $0.pid == 1 }?.iconBundleID == nil,
                        "associate app processes with installed app icons")
            let settings = apps.first { $0.bundleID == "com.apple.Preferences" }
            try require(settings.flatMap { AppIcon.image(for: $0, scale: 2) } != nil,
                        "load the Settings app icon locally")
        }
        try checkThirdParty(apps: idleApps, processes: idleProcesses)
        await service.startServer()
        started = service.status.running
        try require(started, "start the local service")
        let activeApps = try await service.listTargets(spawn: true)
        let activeProcesses = try await service.listTargets(spawn: false)
        try checkThirdParty(apps: activeApps, processes: activeProcesses)
        try require(!activeApps.isEmpty && !activeProcesses.isEmpty, "enumerate targets while the server is running")
        passed = true
    } catch {
        print("FAIL \(error)")
    }
    if started { await service.stopServer() }
    if originallyRunning {
        await service.startServer()
        if !service.status.running {
            print("FAIL restore running server")
            passed = false
        }
    }
    if let imported { try? library.delete(imported) }
    return passed
}

@MainActor
private func runListenerSmoke(service: ServiceClient) async -> Bool {
    func require(_ condition: Bool, _ message: String, expectedError: Bool = false) throws {
        let error = service.operationError ?? service.connectionError ?? ""
        service.operationError = nil
        guard condition else { throw DeviceSmokeError.failed(message + " · " + error) }
        print("PASS " + message + (expectedError ? " · " + error : ""))
        fflush(stdout)
    }

    await service.poll()
    guard service.connected else {
        print("FAIL connect to the app service")
        return false
    }
    let original = service.status
    let known = ReleaseCatalog(major: 16).releases + ReleaseCatalog(major: 17).releases
    let originalRelease = known.first { $0.version == original.version }
    var listener: Int32 = -1
    var passed = false
    do {
        if original.running { await service.stopServer() }
        await service.setListener(address: .loopback, port: original.port)
        try require(!service.status.running && service.status.port == original.port && service.status.address == .loopback,
                    "save address and port while stopped")
        await service.startServer()
        try require(service.status.running && service.status.port == original.port,
                    "start configured listener on port \(original.port)")
        guard let interface = localInterfaceAddress() else {
            throw DeviceSmokeError.failed("no active non-loopback IPv4 interface")
        }
        try require(connectLocally(to: inet_addr("127.0.0.1"), port: service.status.port)
                    && !connectLocally(to: interface, port: service.status.port),
                    "loopback listener rejects other interfaces")

        let wildcard = try makeListener()
        close(wildcard.0)
        await service.setListener(address: .allInterfaces, port: wildcard.1)
        try require(service.status.running && service.status.port == wildcard.1
                    && service.status.address == .allInterfaces
                    && connectLocally(to: interface, port: wildcard.1),
                    "save wildcard address and port together and reach the listener on another interface")
        let fresh = ServiceClient()
        await fresh.poll()
        try require(fresh.status.address == .allInterfaces && fresh.status.port == wildcard.1,
                    "read the effective address and port after reconnecting")

        let conflict = try makeListener()
        listener = conflict.0
        await service.setListener(address: .loopback, port: conflict.1)
        try require(service.operationError != nil && service.status.running
                    && service.status.address == .allInterfaces && service.status.port == wildcard.1
                    && connectLocally(to: interface, port: wildcard.1),
                    "restore address and port after a bind conflict", expectedError: true)
        await service.setListener(address: .loopback, port: wildcard.1)
        try require(service.status.running && service.status.address == .loopback
                    && !connectLocally(to: interface, port: wildcard.1),
                    "switch back to loopback on the same port")

        await service.stopServer()
        await service.setListener(address: .loopback, port: conflict.1)
        guard originalRelease != nil, let alternate = known.first(where: {
            $0.version != service.status.version && service.status.installedVersions.contains($0.version)
        }) else {
            throw DeviceSmokeError.failed("two cached versions required")
        }
        let selected = await service.selectVersion(alternate)
        try require(selected && service.status.version == alternate.version && !service.status.running
                    && service.status.port == conflict.1,
                    "verify and switch versions while stopped even if the configured port is occupied")
        try require(service.logs.last?.text == "已切换到 Frida \(alternate.version)，服务仍处于停止状态。",
                    "report that the service stayed stopped")
        close(listener)
        listener = -1
        await service.startServer()
        try require(service.status.running && service.logs.last?.text
                    == "Frida \(alternate.version) 已在 127.0.0.1:\(conflict.1) 启动。",
                    "report a startup only when the server remains running")
        await service.stopServer()

        passed = true
    } catch {
        print("FAIL \(error)")
    }
    if listener >= 0 { close(listener) }
    if service.status.running { await service.stopServer() }
    if let originalRelease, service.status.version != originalRelease.version {
        _ = await service.selectVersion(originalRelease)
    }
    await service.setListener(address: original.address, port: original.port)
    if original.running { await service.startServer() }
    let restored = service.status.version == original.version && service.status.address == original.address
        && service.status.port == original.port && service.status.running == original.running
    print(restored ? "PASS restore original settings" : "FAIL restore original settings")
    return restored && passed
}

@MainActor
private func runCatalogSmoke(service: ServiceClient) async -> Bool {
    let catalog16 = ReleaseCatalog(major: 16)
    let catalog17 = ReleaseCatalog(major: 17)
    var failed = false
    func require(_ result: Bool, _ title: String) throws {
        if result {
            print("PASS " + title)
            fflush(stdout)
        } else {
            throw DeviceSmokeError.failed(title + " · " + (service.operationError ?? catalog16.error ?? catalog17.error ?? service.connectionError ?? ""))
        }
    }

    await service.poll()
    let originallyInstalled = Set(service.status.installedVersions)
    let original = (catalog16.releases + catalog17.releases).first { $0.version == service.status.version }
    do {
        try require(service.connected, "connect to package helper")
        try require(catalog16.latest.count == 10 && catalog17.latest.count == 10,
                    "load 10 bundled versions per major")
        await catalog16.refresh()
        await catalog17.refresh()
        try require(catalog16.error == nil && catalog17.error == nil
                    && catalog16.latest.count == 10 && catalog16.latest.allSatisfy { $0.major == 16 }
                    && catalog17.latest.count == 10 && catalog17.latest.allSatisfy { $0.major == 17 },
                    "refresh the two GitHub catalogs independently")
        await catalog16.find("16.7.9")
        try require(catalog16.error == nil && catalog16.releases.contains { $0.version == "16.7.9" },
                    "look up an older release within one major")
        let reloaded16 = ReleaseCatalog(major: 16)
        let reloaded17 = ReleaseCatalog(major: 17)
        try require(reloaded16.releases == catalog16.latest && reloaded17.releases == catalog17.latest,
                    "persist only 10 releases per major")
        await service.poll()
        try require(Set(service.status.installedVersions) == originallyInstalled, "browse without downloading any binary")
        guard let old = catalog16.latest.first(where: { $0.version == "16.7.19" }),
              let patch = catalog17.latest.first(where: { !originallyInstalled.contains($0.version) }),
              let bundled = catalog17.latest.first(where: { $0.version == "17.27.4" }) else {
            throw DeviceSmokeError.failed("required releases missing")
        }
        let port = service.status.port
        await service.startServer()
        try require(service.status.running, "start currently selected server")

        let downloadedOld = await service.downloadVersion(old)
        try require(downloadedOld, "ensure the Frida 16 release is downloaded")
        let selectedOld = await service.selectVersion(old)
        try require(selectedOld && service.status.version == old.version && service.status.running
            && service.status.port == port && service.status.installedVersions.contains(old.version),
            "switch a running server to 16.7.19 on the same port")
        let fresh = ServiceClient()
        await fresh.poll()
        try require(fresh.status.version == old.version && fresh.status.running, "recover 16.x selection on reconnect")
        let prematureSwitch = await service.selectVersion(patch)
        try require(!prematureSwitch && service.status.version == old.version && service.status.running
                    && !service.status.installedVersions.contains(patch.version),
                    "require an explicit download before switching")
        service.operationError = nil
        var samples: [ReleaseDownloadProgress] = []
        let transfer = service.$downloadProgress.compactMap { $0 }.sink { samples.append($0) }
        let downloadedPatch = await service.downloadVersion(patch)
        transfer.cancel()
        try require(downloadedPatch && service.status.installedVersions.contains(patch.version)
                    && service.status.version == old.version && service.status.running && service.status.port == port,
                    "download Frida " + patch.version + " without changing the running service")
        try require(samples.contains { $0.receivedBytes > 0 && $0.receivedBytes < $0.totalBytes }
                    && Set(samples.map(\.receivedBytes)).count > 2, "report changing byte counts and a real percentage")
        let selectedPatch = await service.selectVersion(patch)
        try require(selectedPatch && service.status.version == patch.version && service.status.running,
                    "switch only after a separate action")
        let selectedBundled = await service.selectVersion(bundled)
        try require(selectedBundled && service.status.version == bundled.version && service.status.running,
                    "switch within the same protocol major")
        await service.stopServer()
        let selectWhileStopped = await service.selectVersion(old)
        try require(selectWhileStopped && service.status.version == old.version && !service.status.running,
                    "switch to a cached release while the server is stopped")
    } catch {
        print("FAIL \(error)")
        failed = true
    }
    if service.status.sessionPID != nil { await service.stopSession() }
    await service.stopServer()
    if let original, service.status.version != original.version {
        service.operationError = nil
        _ = await service.selectVersion(original)
    }
    print("DONE")
    return !failed
}

private enum DeviceSmokeError: Error {
    case failed(String)
}

private func localInterfaceAddress() -> in_addr_t? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return nil }
    defer { freeifaddrs(head) }
    var node: UnsafeMutablePointer<ifaddrs>? = head
    while let current = node {
        let interface = current.pointee
        if let address = interface.ifa_addr, address.pointee.sa_family == AF_INET,
           interface.ifa_flags & UInt32(IFF_UP | IFF_LOOPBACK) == UInt32(IFF_UP) {
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        }
        node = interface.ifa_next
    }
    return nil
}

private func connectLocally(to host: in_addr_t, port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    address.sin_len = UInt8(length)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = host
    address.sin_port = UInt16(port).bigEndian
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) == 0 }
    }
}

private func makeListener() throws -> (Int32, Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DeviceSmokeError.failed("create temporary loopback socket") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            guard bind(fd, socketAddress, length) == 0, listen(fd, 1) == 0 else { return -1 }
            return Int(getsockname(fd, socketAddress, &length))
        }
    }
    guard result == 0 else {
        close(fd)
        throw DeviceSmokeError.failed("bind temporary loopback socket")
    }
    return (fd, Int(UInt16(bigEndian: address.sin_port)))
}
#endif
