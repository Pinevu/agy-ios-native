import SwiftUI

/// 实例列表：添加 / 切换 / 删除
struct InstancesSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newURL = ""
    @State private var busy = false
    @State private var status: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(state.instances) { inst in
                        Button {
                            Task {
                                busy = true
                                await state.switchInstance(inst)
                                busy = false
                                if state.isLoggedIn { dismiss() }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: inst.id == state.currentInstanceId
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(inst.id == state.currentInstanceId
                                                     ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(inst.name)
                                        .font(.system(size: 15))
                                        .foregroundStyle(.primary)
                                    Text(inst.url)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Text(status[inst.id] ?? "")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                state.removeInstance(inst)
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("点击切换")
                }

                Section {
                    TextField("名称（可留空自动识别）", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("地址，如 https://nl.nooh.cc", text: $newURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task {
                            busy = true
                            await state.addInstance(name: newName, url: newURL)
                            newName = ""; newURL = ""
                            busy = false
                            await refreshStatus()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if busy { ProgressView().scaleEffect(0.7) }
                            Text("添加实例")
                        }
                    }
                    .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("添加")
                } footer: {
                    Text("两台机器共用同一份密钥签发的登录态，密码输一次即可在实例间切换。")
                        .font(.system(size: 11.5))
                }
            }
            .navigationTitle("实例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .task { await refreshStatus() }
        }
    }

    private func refreshStatus() async {
        for inst in state.instances {
            if let name = await AppState.probe(inst.url) {
                status[inst.id] = name.isEmpty ? "在线" : "在线 · \(name)"
            } else {
                status[inst.id] = "离线"
            }
        }
    }
}
