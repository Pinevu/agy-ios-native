import Foundation

/// 环境变量、MCP 服务器、Agent 记忆与推理参数同步扩展
extension AppState {

    // MARK: - 实例全量能力预拉取

    func refreshAgentCapabilities(forEpoch: Int? = nil) async {
        let epoch = forEpoch ?? instanceEpoch
        async let eTask: Void = refreshEnvVars(forEpoch: epoch)
        async let mTask: Void = refreshMCPServers(forEpoch: epoch)
        async let aTask: Void = refreshAgentMemory(forEpoch: epoch)
        _ = await (eTask, mTask, aTask)
    }

    var enabledEnvCount: Int {
        envVars.filter(\.enabled).count
    }

    var enabledMCPCount: Int {
        mcpServers.filter(\.enabled).count
    }

    var effortDisplayBadge: String? {
        switch reasoningEffort {
        case "low": return "Low"
        case "medium": return "Med"
        case "high": return "High"
        case "xhigh": return "XHigh"
        case "max": return "Max"
        default: return nil
        }
    }

    // MARK: - 环境变量（Environment Variables）

    func refreshEnvVars(forEpoch: Int? = nil) async {
        let epoch = forEpoch ?? instanceEpoch
        guard let resp = try? await api.envVars() else { return }
        guard epoch == instanceEpoch else { return }
        if let list = resp.vars, envVars != list { envVars = list }
        if let pm = resp.privacyMode, envPrivacyMode != pm { envPrivacyMode = pm }
    }

    func saveEnvVar(id: String? = nil, key: String, value: String, note: String, enabled: Bool) async -> String? {
        var payload: [String: Any] = [
            "action": "upsert",
            "key": key,
            "value": value,
            "note": note,
            "enabled": enabled
        ]
        if let id, !id.isEmpty { payload["id"] = id }
        do {
            let resp = try await api.postEnv(payload)
            if resp.ok == true {
                if let list = resp.vars { envVars = list }
                if let pm = resp.privacyMode { envPrivacyMode = pm }
                showToast(id == nil ? "已添加 \(key)" : "已更新 \(key)")
                return nil
            }
            return resp.error ?? "保存失败"
        } catch {
            return error.localizedDescription
        }
    }

    func batchImportEnvVars(_ text: String) async -> String? {
        do {
            let resp = try await api.postEnv(["action": "batch_import", "text": text])
            if resp.ok == true {
                if let list = resp.vars { envVars = list }
                let count = resp.imported ?? 0
                showToast("已导入 \(count) 项环境变量")
                return nil
            }
            return resp.error ?? "导入失败"
        } catch {
            return error.localizedDescription
        }
    }

    func toggleEnvVar(_ item: EnvVarItem) async {
        do {
            let resp = try await api.postEnv(["action": "toggle", "id": item.id])
            if let list = resp.vars { envVars = list }
            showToast(item.enabled ? "已停用 \(item.key)" : "已启用 \(item.key)")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func setEnvPrivacyMode(_ enabled: Bool) async {
        let prev = envPrivacyMode
        envPrivacyMode = enabled
        do {
            let resp = try await api.postEnv(["action": "privacy", "privacy_mode": enabled])
            if let pm = resp.privacyMode { envPrivacyMode = pm }
            showToast(envPrivacyMode ? "已开启工具输出脱敏" : "已关闭工具输出脱敏")
        } catch {
            envPrivacyMode = prev
            showToast(error.localizedDescription)
        }
    }

    func deleteEnvVar(_ item: EnvVarItem) async {
        do {
            let resp = try await api.deleteEnv(item.id)
            if let list = resp.vars {
                envVars = list
            } else {
                envVars.removeAll { $0.id == item.id }
            }
            showToast("已删除 \(item.key)")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    // MARK: - MCP 服务器（Model Context Protocol）

    func refreshMCPServers(forEpoch: Int? = nil) async {
        let epoch = forEpoch ?? instanceEpoch
        guard let resp = try? await api.mcpList() else { return }
        guard epoch == instanceEpoch else { return }
        if let list = resp.servers, mcpServers != list { mcpServers = list }
        if let presets = resp.presets, mcpPresets != presets { mcpPresets = presets }
    }

    func saveMCPServer(_ payload: [String: Any], isNew: Bool) async -> String? {
        do {
            let resp = try await api.upsertMCP(payload)
            if resp.ok == true {
                if let list = resp.servers { mcpServers = list }
                let sid = (payload["id"] as? String) ?? ""
                showToast(isNew ? "已添加 MCP「\(sid)」" : "已更新 MCP「\(sid)」")
                return nil
            }
            return resp.error ?? "保存失败"
        } catch {
            return error.localizedDescription
        }
    }

    func importMCPFromJSON(_ rawJSON: String) async -> String? {
        do {
            let resp = try await api.importMCPJSON(rawJSON)
            if resp.ok == true {
                if let list = resp.servers { mcpServers = list }
                let n = resp.imported?.count ?? 1
                showToast("已导入 \(n) 个 MCP 服务器")
                return nil
            }
            return resp.error ?? "导入失败"
        } catch {
            return error.localizedDescription
        }
    }

    func toggleMCPServer(_ server: MCPServerItem) async {
        do {
            let resp = try await api.toggleMCP(server.id)
            if let list = resp.servers { mcpServers = list }
            showToast(server.enabled ? "已停用 \(server.id)" : "已启用 \(server.id)")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func deleteMCPServer(_ server: MCPServerItem) async {
        do {
            let resp = try await api.deleteMCP(server.id)
            if let list = resp.servers {
                mcpServers = list
            } else {
                mcpServers.removeAll { $0.id == server.id }
            }
            showToast("已移除 \(server.id)")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func probeMCPServer(_ id: String) async -> MCPProbeResponse {
        do {
            let resp = try await api.probeMCP(id)
            if let idx = mcpServers.firstIndex(where: { $0.id == id }) {
                mcpServers[idx].lastOk = (resp.ok == true)
                if resp.ok == true, let tc = resp.toolsCount {
                    mcpServers[idx].toolsCount = tc
                }
            }
            return resp
        } catch {
            return MCPProbeResponse(
                ok: false,
                id: id,
                latencyMs: nil,
                toolsCount: nil,
                tools: nil,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Agent 人格设定与持久记忆（GEMINI.md）

    func refreshAgentMemory(forEpoch: Int? = nil) async {
        let epoch = forEpoch ?? instanceEpoch
        guard let resp = try? await api.agentMemory() else { return }
        guard epoch == instanceEpoch else { return }
        applyAgentMemoryResponse(resp)
    }

    private func applyAgentMemoryResponse(_ resp: AgentMemoryResponse) {
        if let en = resp.enabled, agentMemoryEnabled != en { agentMemoryEnabled = en }
        if let inj = resp.injectNotes, agentInjectNotes != inj { agentInjectNotes = inj }
        if let s = resp.soul, agentSoul != s { agentSoul = s }
        if let gm = resp.globalMemory, globalMemory != gm { globalMemory = gm }
        if let fs = resp.files, memoryFiles != fs { memoryFiles = fs }
        if let cc = resp.charCount, memoryCharCount != cc { memoryCharCount = cc }
        if let cl = resp.charLimit, memoryCharLimit != cl { memoryCharLimit = cl }
    }

    func saveAgentProfile(
        enabled: Bool,
        injectNotes: Bool,
        soul: AgentSoulConfig,
        globalMemoryText: String
    ) async -> String? {
        let payload: [String: Any] = [
            "action": "save_profile",
            "enabled": enabled,
            "inject_notes": injectNotes,
            "global_memory": globalMemoryText,
            "soul": [
                "name": soul.name,
                "role": soul.role,
                "style": soul.style,
                "language": soul.language,
                "rules": soul.rules
            ]
        ]
        do {
            let resp = try await api.saveAgentMemory(payload)
            if resp.ok == true {
                applyAgentMemoryResponse(resp)
                showToast("已同步至全局 GEMINI.md")
                return nil
            }
            return resp.error ?? "保存失败"
        } catch {
            return error.localizedDescription
        }
    }

    func saveMemoryNoteFile(name: String, content: String) async -> String? {
        let payload: [String: Any] = [
            "action": "save_file",
            "name": name,
            "content": content
        ]
        do {
            let resp = try await api.saveAgentMemory(payload)
            if resp.ok == true {
                applyAgentMemoryResponse(resp)
                showToast("已保存记忆笔记")
                return nil
            }
            return resp.error ?? "保存失败"
        } catch {
            return error.localizedDescription
        }
    }

    func deleteMemoryNoteFile(_ file: MemoryNoteFile) async {
        do {
            let resp = try await api.deleteAgentMemoryFile(file.name)
            if let fs = resp.files { memoryFiles = fs }
            if let cc = resp.charCount { memoryCharCount = cc }
            showToast("已删除 \(file.name)")
        } catch {
            showToast(error.localizedDescription)
        }
    }
}
