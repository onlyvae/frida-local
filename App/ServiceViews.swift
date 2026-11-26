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
                        Text(coloredLog(log))
                            .font(.system(.footnote, design: .monospaced))
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

    private func coloredLog(_ log: LogEntry) -> AttributedString {
        let color: UIColor = log.kind == "error" ? .systemRed : .label
        let styled = FLColorizedLog(log.text, [.foregroundColor: color], .systemBackground)
        var line = AttributedString()
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attributes, range, _ in
            var run = AttributedString((styled.string as NSString).substring(with: range))
            if let foreground = attributes[.foregroundColor] as? UIColor {
                run.foregroundColor = Color(uiColor: foreground)
            }
            if let background = attributes[.backgroundColor] as? UIColor {
                run.backgroundColor = Color(uiColor: background)
            }
            line.append(run)
        }
        return line
    }
}

struct ServerSettingsView: View {
    @EnvironmentObject private var service: ServiceClient
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
            Section {
                Toggle("显示运行浮层", isOn: Binding(get: { service.overlayEnabled }, set: service.setOverlayEnabled))
                    .disabled(!service.connected || service.savingOverlayEnabled)
                if service.overlayEnabled {
                    let percentage = service.overlayTransparency.formatted(.percent.precision(.fractionLength(0)))
                    LabeledValue(label: "背景透明度", value: percentage)
                    Slider(value: Binding(get: { service.overlayTransparency }, set: service.setOverlayTransparency),
                           in: 0...FLMaximumOverlayTransparency, step: 0.05)
                        .accessibilityLabel("浮层背景透明度")
                        .accessibilityValue(percentage)
                        .disabled(!service.connected)
                }
            } header: {
                Text("运行浮层")
            } footer: {
                Text("开启后，运行脚本时会显示浮层。")
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
