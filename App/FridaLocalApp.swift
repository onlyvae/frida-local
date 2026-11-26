import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if !FL_DEVICE_SMOKE
@main
#endif
struct FridaLocalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = ScriptLibrary()
    @StateObject private var service = ServiceClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(service)
                #if FL_DEVICE_SMOKE
                .task { await runDeviceSmoke(library: library, service: service) }
                #endif
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await service.poll()
                        try? await Task.sleep(nanoseconds: 750_000_000)
                    }
                }
        }
    }
}

private struct RootView: View {
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var service: ServiceClient
    @State private var selection = Tab.scripts
    @State private var importing = false
    @State private var presentedScript: LocalScript?
    @State private var fileError: String?

    private enum Tab { case scripts, console, settings }

    var body: some View {
        TabView(selection: $selection) {
            NavigationView {
                Group {
                    if library.scripts.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 46, weight: .light))
                                .foregroundStyle(Color.accentColor)
                            Text("还没有脚本").font(.title2.bold())
                            Button("导入脚本") { importing = true }.buttonStyle(.borderedProminent)
                            if Bundle.main.url(forResource: "hello", withExtension: "js") != nil {
                                Button("导入示例") { importExample() }
                            }
                            if let message = library.loadError {
                                Text(message).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemGroupedBackground))
                    } else {
                        List {
                            if let message = library.loadError {
                                Text(message).font(.footnote).foregroundStyle(.secondary)
                            }
                            ForEach(library.scripts) { script in
                                Button { presentedScript = script } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(script.name).foregroundStyle(.primary).lineLimit(1)
                                            Text(script.importedAt, style: .date)
                                                .font(.footnote).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                }
                .navigationTitle("脚本库")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { importing = true } label: { Label("导入脚本", systemImage: "plus") }
                    }
                }
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("脚本", systemImage: "doc.on.doc") }.tag(Tab.scripts)

            NavigationView { ConsoleView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("日志", systemImage: "terminal") }.tag(Tab.console)
            NavigationView { ServerSettingsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText]) { result in
            do { _ = try library.importFile(result.get()) } catch { fileError = error.localizedDescription }
        }
        .sheet(item: $presentedScript) { script in
            NavigationView {
                ScriptDetails(script: script, opensInSpawn: !library.recentApps(for: script).isEmpty) {
                    selection = .console
                }
            }
            .navigationViewStyle(.stack)
        }
        .alert("操作失败", isPresented: Binding(
            get: { fileError != nil || (presentedScript == nil && service.operationError != nil) },
            set: { if !$0 { fileError = nil; service.operationError = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: {
            Text(fileError ?? service.operationError ?? "")
        }
    }

    private func importExample() {
        guard let url = Bundle.main.url(forResource: "hello", withExtension: "js") else { return }
        do { _ = try library.importFile(url) } catch { fileError = error.localizedDescription }
    }
}

private struct ScriptDetails: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: ScriptLibrary
    @EnvironmentObject private var service: ServiceClient
    let script: LocalScript
    let onRun: () -> Void
    @AppStorage("thirdPartyTargetsOnly") private var thirdPartyOnly = true
    @State private var selectedApp: TargetInventoryEntry?
    @State private var selectedProcess: TargetInventoryEntry?
    @State private var spawn: Bool
    @State private var showingSource = false
    @State private var confirmingDelete = false
    @State private var error: String?

    init(script: LocalScript, opensInSpawn: Bool, onRun: @escaping () -> Void) {
        self.script = script
        self.onRun = onRun
        _spawn = State(initialValue: opensInSpawn)
    }

    private var selected: TargetInventoryEntry? {
        let entry = spawn ? selectedApp : selectedProcess
        return !thirdPartyOnly || entry?.isThirdParty == true ? entry : nil
    }

    private var appToRestore: String? {
        guard spawn, service.connected else { return nil }
        return library.recentApps(for: script).first
    }

    private var canRun: Bool {
        guard let selected else { return false }
        return spawn ? selected.bundleID != nil : selected.pid != nil
    }

    var body: some View {
        Form {
            Section("运行") {
                Picker("模式", selection: $spawn) {
                    Text("Attach").tag(false)
                    Text("Spawn").tag(true)
                }
                .pickerStyle(.segmented)

                NavigationLink {
                    ScriptTargetPicker(spawn: spawn, selectionID: selected?.id,
                                       recentAppIDs: spawn ? library.recentApps(for: script) : [],
                                       thirdPartyOnly: $thirdPartyOnly,
                                       load: { try await service.listTargets(spawn: $0) },
                                       select: selectTarget)
                } label: {
                    HStack {
                        Text("目标")
                        Spacer()
                        if let selected {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(selected.name).lineLimit(1)
                                Text(selected.detail).font(.caption).lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Text(spawn ? "选择应用" : "选择进程").foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!service.connected || service.busy)

                if !service.status.running || !service.connected {
                    Text("在设置中启动 frida-server 后即可运行脚本。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if service.status.sessionPID != nil {
                    Text("已有会话运行中，可在日志页停止。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Button {
                    guard let selected, canRun else { return }
                    let requestedSpawn = spawn
                    let bundleID = selected.bundleID
                    let pid = selected.pid ?? 0
                    Task {
                        if await service.run(script, bundleID: bundleID, pid: pid, spawn: requestedSpawn) {
                            dismiss()
                            onRun()
                        }
                    }
                } label: {
                    Label("运行脚本", systemImage: "play.fill")
                }
                .disabled(!canRun || !service.connected || !service.status.running || service.busy
                    || service.status.sessionPID != nil)
            }
            Section("文件") {
                Button {
                    showingSource = true
                } label: {
                    Label("查看", systemImage: "doc.text")
                }
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .navigationTitle(script.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        .onChange(of: spawn) { _ in selectedProcess = nil }
        .onChange(of: thirdPartyOnly) { enabled in
            if enabled && selectedProcess?.isThirdParty == false { selectedProcess = nil }
        }
        .task(id: appToRestore) { await restoreApp() }
        .sheet(isPresented: $showingSource) {
            ScriptSourceSheet(script: script)
        }
        .confirmationDialog("删除此脚本？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                do { try library.delete(script); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
        .alert("运行或文件操作失败", isPresented: Binding(
            get: { error != nil || service.operationError != nil },
            set: { if !$0 { error = nil; service.operationError = nil } }
        )) {
            Button("好", role: .cancel) { }
        } message: { Text(error ?? service.operationError ?? "") }
    }

    private func selectTarget(_ entry: TargetInventoryEntry) {
        if spawn {
            guard let bundleID = entry.bundleID else { return }
            selectedApp = entry
            library.recordAppSelection(bundleID, for: script)
        } else {
            selectedProcess = entry
        }
    }

    private func restoreApp() async {
        guard let bundleID = appToRestore, selectedApp == nil,
              let apps = try? await service.listTargets(spawn: true),
              !Task.isCancelled, selectedApp == nil else { return }
        selectedApp = apps.first { $0.bundleID == bundleID }
    }
}

private struct ScriptTargetPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    let spawn: Bool
    let selectionID: String?
    let recentAppIDs: [String]
    @Binding var thirdPartyOnly: Bool
    let load: (Bool) async throws -> [TargetInventoryEntry]
    let select: (TargetInventoryEntry) -> Void
    @State private var entries: [TargetInventoryEntry] = []
    @State private var search = ""
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?

    private var visible: [TargetInventoryEntry] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (!thirdPartyOnly || entry.isThirdParty) && (term.isEmpty
                || entry.name.localizedStandardContains(term) || entry.detail.localizedStandardContains(term))
        }
    }

    private var emptyMessage: String {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "没有匹配的目标。" }
        if thirdPartyOnly { return spawn ? "未找到第三方应用。" : "未找到运行中的第三方应用进程。" }
        return spawn ? "未找到已安装应用。" : "未找到运行中进程。"
    }

    var body: some View {
        let visible = visible
        let recent = recentAppIDs.compactMap { bundleID in visible.first { $0.bundleID == bundleID } }
        let recentIDs = Set(recent.map(\.id))

        List {
            Section {
                Toggle("仅第三方 App", isOn: $thirdPartyOnly)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            if entries.isEmpty && (loading || !loaded) && error == nil {
                VStack(spacing: 6) {
                    ProgressView()
                        .accessibilityHidden(true)
                    Text("正在读取目标…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if visible.isEmpty && error == nil {
                Text(emptyMessage).foregroundStyle(.secondary)
            }
            if !recent.isEmpty {
                Section("最近选择") {
                    ForEach(recent, content: targetRow)
                }
            }
            ForEach(visible.filter { !recentIDs.contains($0.id) }, content: targetRow)
        }
        .navigationTitle(spawn ? "选择应用" : "选择进程")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: spawn ? "搜索名称或 Bundle ID" : "搜索名称或 PID")
        .task { if !loaded { await reload() } }
        .refreshable { await reload() }
    }

    private func targetRow(_ entry: TargetInventoryEntry) -> some View {
        Button {
            select(entry)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                targetIcon(entry)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).foregroundStyle(.primary)
                    Text(entry.detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.id == selectionID {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func targetIcon(_ entry: TargetInventoryEntry) -> some View {
        Group {
            if let icon = AppIcon.image(for: entry, scale: displayScale) {
                Image(uiImage: icon).renderingMode(.original).resizable().scaledToFit()
            } else {
                Image(systemName: spawn ? "app" : "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .tertiarySystemFill))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result = try await load(spawn)
            guard !Task.isCancelled else { return }
            entries = result
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
