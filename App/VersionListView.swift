import SwiftUI

struct VersionListView: View {
    @EnvironmentObject private var service: ServiceClient

    var body: some View {
        List {
            ForEach([16, 17], id: \.self) { major in
                NavigationLink {
                    VersionGroupView(major: major)
                } label: {
                    HStack {
                        Text("Frida \(major)")
                        Spacer()
                        if FridaRelease.components(of: service.status.version)?.first == major {
                            Text("当前 \(service.status.version)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Frida 版本")
    }
}

private struct VersionGroupView: View {
    @EnvironmentObject private var service: ServiceClient
    @StateObject private var catalog: ReleaseCatalog
    @State private var query = ""
    let major: Int

    init(major: Int) {
        self.major = major
        _catalog = StateObject(wrappedValue: ReleaseCatalog(major: major))
    }

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visible: [FridaRelease] {
        searchTerm.isEmpty ? catalog.releases : catalog.releases.filter { $0.version.contains(searchTerm) }
    }

    var body: some View {
        List {
            if let error = catalog.error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                ForEach(visible) { release in
                    versionRow(release)
                }
                if FridaRelease.components(of: searchTerm)?.first == major,
                   !visible.contains(where: { $0.version == searchTerm }) {
                    Button("在 GitHub 查找 \(searchTerm)") {
                        let version = searchTerm
                        Task { await catalog.find(version) }
                    }
                    .disabled(catalog.loading)
                }
                if searchTerm.isEmpty && catalog.hasMore {
                    Button("加载更早版本") { Task { await catalog.loadMore() } }
                        .disabled(catalog.loading)
                }
                if catalog.loading { ProgressView() }
            } header: {
                Text("GitHub 正式版")
            } footer: {
                if let checked = catalog.lastChecked {
                    Text("上次刷新 \(checked.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("下拉刷新 GitHub 版本列表。")
                }
            }
            if service.status.sessionPID != nil {
                Section { Text("停止当前会话后即可切换版本。").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Frida \(major)")
        .searchable(text: $query, prompt: "搜索版本号")
        .refreshable { await catalog.refresh() }
        .task { await catalog.refreshIfNeeded() }
    }

    private func versionRow(_ release: FridaRelease) -> some View {
        let selected = service.status.version == release.version
        let installed = service.status.installedVersions.contains(release.version)
        let working = service.pendingVersion == release.version
        let canAct = !selected && service.connected && !service.busy && service.status.sessionPID == nil
        let title = selected ? "当前版本" : (installed ? "切换" : "下载")
        let symbol = selected ? "checkmark.circle.fill" : (installed ? "arrow.left.arrow.right" : "arrow.down.to.line")

        return HStack {
            Text(release.version).monospacedDigit()
            Spacer()
            Button {
                Task {
                    if installed { await service.selectVersion(release) }
                    else { await service.downloadVersion(release) }
                }
            } label: {
                Group {
                    if working {
                        actionProgress
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(selected ? Color.green : (canAct ? Color.accentColor : Color.secondary))
                    }
                }
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canAct)
            .accessibilityLabel(Text("\(title) \(release.version)"))
            .accessibilityValue(working ? actionStatus : "")
        }
    }

    @ViewBuilder
    private var actionProgress: some View {
        if service.isDownloading, let progress = service.downloadProgress, !progress.validating,
           let fraction = progress.fraction, progress.receivedBytes > 0 {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
            }
            .frame(width: 27, height: 27)
            .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
    }

    private var actionStatus: String {
        guard service.isDownloading else { return "切换中" }
        guard let progress = service.downloadProgress else { return "连接中" }
        if progress.validating { return "校验中" }
        if let fraction = progress.fraction { return "已下载 \(Int(fraction * 100))%" }
        if progress.receivedBytes > 0 {
            return "已下载 \(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file))"
        }
        return "连接中"
    }
}
