import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var service: ServiceClient

    var body: some View {
        List {
            if let pid = service.status.sessionPID {
                Section("当前会话") {
                    LabeledValue(label: service.status.sessionName ?? "脚本", value: "PID \(pid)")
                    Button("停止会话", role: .destructive) { Task { await service.stopSession() } }
                        .disabled(service.busy)
                }
            }
            if service.logs.isEmpty {
                Text("运行脚本后，输出和错误会显示在这里。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Section("输出") {
                    ForEach(service.logs.reversed()) { log in
                        Text(log.text)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(log.kind == "error" ? Color.red : Color.primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("日志")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") { service.clearLogs() }.disabled(service.logs.isEmpty)
            }
        }
    }
}

struct ServerSettingsView: View {
    @EnvironmentObject private var service: ServiceClient
    @AppStorage("thirdPartyTargetsOnly") private var thirdPartyOnly = true
    @State private var address = ListenAddress.loopback
    @State private var portText = ""
    @State private var confirmingStop = false
    @FocusState private var editingPort: Bool

    private var port: Int? {
        guard let port = Int(portText), (1024...65535).contains(port) else { return nil }
        return port
    }

    private var canEditListener: Bool {
        service.connected && !service.busy && service.status.sessionPID == nil
    }

    var body: some View {
        Form {
            Section {
                LabeledValue(label: "状态", value: !service.connected ? "管理服务未连接" : (service.status.running ? "运行中" : "已停止"))
                NavigationLink {
                    VersionListView()
                } label: {
                    LabeledValue(label: "版本", value: service.status.version.isEmpty ? "选择版本" : service.status.version)
                }
                Picker("地址", selection: $address) {
                    Text("127.0.0.1").tag(ListenAddress.loopback)
                    Text("0.0.0.0").tag(ListenAddress.allInterfaces)
                }
                .disabled(!canEditListener)
                HStack {
                    Text("端口")
                    Spacer()
                    TextField("1024–65535", text: $portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($editingPort)
                        .accessibilityLabel("端口")
                }
                .disabled(!canEditListener)
                Button("保存配置") {
                    guard let port else { return }
                    editingPort = false
                    Task { await service.setListener(address: address, port: port) }
                }
                .disabled(!canEditListener || port == nil || (port == service.status.port && address == service.status.address))
                if service.status.running {
                    Button("停止服务", role: .destructive) {
                        if service.status.sessionPID != nil { confirmingStop = true }
                        else { Task { await service.stopServer() } }
                    }
                    .disabled(!service.connected || service.busy)
                } else {
                    Button("启动服务") { Task { await service.startServer() } }
                        .disabled(!service.connected || service.busy)
                }
                if service.busy { ProgressView() }
                if let message = service.connectionError ?? service.status.serverError {
                    Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Frida Server")
            } footer: {
                if service.status.sessionPID != nil {
                    Text("停止当前会话后可修改监听配置。")
                } else if service.status.running {
                    Text("保存配置会重启服务。")
                }
            }
            Section("设备") {
                Toggle("仅第三方 App", isOn: $thirdPartyOnly)
            }
        }
        .navigationTitle("设置")
        .onAppear {
            address = service.status.address
            portText = String(service.status.port)
        }
        .onChange(of: service.status.address) { address = $0 }
        .onChange(of: service.status.port) { portText = String($0) }
        .confirmationDialog("停止服务会结束当前会话。", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("停止服务", role: .destructive) { Task { await service.stopServer() } }
        }
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
