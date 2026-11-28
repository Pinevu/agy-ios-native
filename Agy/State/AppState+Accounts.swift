import Foundation
import UIKit

/// Antigravity 同机多 Google 账号池管理（切换不中断运行中任务、100% 保留会话与配置）
extension AppState {

    var activeAccount: AgyAccountItem? {
        if let aid = activeAccountId, let hit = accounts.first(where: { $0.id == aid }) {
            return hit
        }
        return accounts.first(where: { $0.active }) ?? accounts.first
    }

    var hasMultipleAccounts: Bool {
        accounts.count > 1
    }

    func refreshAccounts(withQuota: Bool = true, force: Bool = false, forEpoch: Int? = nil) async {
        let epoch = forEpoch ?? instanceEpoch
        if !withQuota && accounts.isEmpty {
            isLoadingAccounts = true
        } else if withQuota {
            isLoadingAccounts = true
        }
        defer {
            if epoch == instanceEpoch { isLoadingAccounts = false }
        }
        guard let resp = try? await api.accounts(withQuota: withQuota, force: force),
              resp.ok != false,
              let list = resp.accounts else { return }
        guard epoch == instanceEpoch else { return }

        // 当 withQuota == false 时，尽量保留内存中已拉取到的配额展示，避免闪烁丢失
        let merged: [AgyAccountItem]
        if !withQuota && !accounts.isEmpty {
            let oldById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            merged = list.map { fresh in
                guard (fresh.quotaGroups ?? []).isEmpty, let old = oldById[fresh.id], !(old.quotaGroups ?? []).isEmpty else {
                    return fresh
                }
                return AgyAccountItem(
                    id: fresh.id,
                    email: fresh.email,
                    label: fresh.label,
                    authMethod: fresh.authMethod,
                    active: fresh.active,
                    isPrimary: fresh.isPrimary,
                    addedAt: fresh.addedAt,
                    lastUsedAt: fresh.lastUsedAt,
                    runningTasks: fresh.runningTasks,
                    plan: fresh.plan ?? old.plan,
                    tier: fresh.tier ?? old.tier,
                    quotaOk: old.quotaOk,
                    quotaGroups: old.quotaGroups,
                    quotaError: old.quotaError
                )
            }
        } else {
            merged = list
        }

        if accounts != merged {
            accounts = merged
        }
        let nextActive = resp.activeId ?? merged.first(where: { $0.active })?.id
        if activeAccountId != nextActive {
            activeAccountId = nextActive
        }
    }

    /// 切换当前 VPS 的活跃 Antigravity 账号（绝不清空会话/历史/任务，仅切换后续请求凭证并刷新模型与配额）
    @discardableResult
    func switchAccount(to acct: AgyAccountItem, silent: Bool = false) async -> Bool {
        guard !isSwitchingAccount else { return false }
        let epoch = instanceEpoch
        isSwitchingAccount = true
        defer {
            if epoch == instanceEpoch { isSwitchingAccount = false }
        }

        do {
            let res = try await api.switchAccount(acct.id)
            guard epoch == instanceEpoch else { return false }
            guard res.ok != false else {
                showToast(res.error ?? "切换账号失败")
                return false
            }

            let targetId = res.activeId ?? acct.id
            activeAccountId = targetId
            accounts = accounts.map { item in
                var copy = item
                copy.active = (item.id == targetId)
                return copy
            }

            // 并行刷新新账号可用模型与最新配额，不干扰任何会话与运行中任务
            async let mdlTask: Void = refreshModels(force: true, forEpoch: epoch)
            async let qTask: Void = prefetchQuotaForWidget(force: true, forEpoch: epoch)
            _ = await (mdlTask, qTask)
            guard epoch == instanceEpoch else { return false }

            var fallbackNotice: String? = nil
            if !modelOptions.isEmpty && !modelOptions.contains(where: { $0.id == model }) {
                let wantThirdParty = model.lowercased().contains("claude") || model.lowercased().contains("gpt")
                let candidate = modelOptions.first(where: {
                    let low = $0.id.lowercased()
                    return (low.contains("claude") || low.contains("gpt")) == wantThirdParty
                }) ?? modelOptions[0]
                setModel(candidate.id)
                fallbackNotice = "，模型已自动回退为 \(candidate.short)"
            }

            if !silent {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showToast("已切换至 \(acct.displayLabel)（会话与任务已保留\(fallbackNotice ?? "")）")
            }
            Task { await refreshAccounts(withQuota: true, force: false, forEpoch: epoch) }
            return true
        } catch {
            showToast("切换账号失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func renameAccount(_ acct: AgyAccountItem, to newLabel: String) async -> Bool {
        let clean = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        do {
            let res = try await api.renameAccount(id: acct.id, label: clean)
            guard res.ok != false else {
                showToast(res.error ?? "修改备注失败")
                return false
            }
            accounts = accounts.map { item in
                guard item.id == acct.id else { return item }
                var copy = item
                copy.label = clean
                return copy
            }
            showToast("已更新备注为「\(clean)」")
            return true
        } catch {
            showToast("修改备注失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func deleteAccount(_ acct: AgyAccountItem) async -> Bool {
        let epoch = instanceEpoch
        do {
            let res = try await api.deleteAccount(acct.id)
            guard epoch == instanceEpoch else { return false }
            guard res.ok != false else {
                showToast(res.error ?? "删除账号失败")
                return false
            }
            await refreshAccounts(withQuota: true, force: false, forEpoch: epoch)
            await refreshModels(force: true, forEpoch: epoch)
            await prefetchQuotaForWidget(force: true, forEpoch: epoch)
            showToast("已移除账号 \(acct.email)")
            return true
        } catch {
            showToast("删除账号失败：\(error.localizedDescription)")
            return false
        }
    }

    func importAccountToken(json: String, label: String, switchAfter: Bool) async -> (ok: Bool, message: String) {
        let epoch = instanceEpoch
        do {
            let res = try await api.importAccountToken(json, label: label, switchAfter: switchAfter)
            guard epoch == instanceEpoch else { return (false, "已切换服务器实例") }
            guard res.ok != false else {
                return (false, res.error ?? "导入凭证失败")
            }
            await refreshAccounts(withQuota: true, force: true, forEpoch: epoch)
            if switchAfter {
                async let m: Void = refreshModels(force: true, forEpoch: epoch)
                async let q: Void = prefetchQuotaForWidget(force: true, forEpoch: epoch)
                _ = await (m, q)
            }
            let email = res.account?.email ?? "新账号"
            let action = res.updatedExisting == true ? "已更新凭证" : "已添加"
            let msg = "\(action)：\(email)"
            showToast(msg)
            return (true, msg)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func startOAuthAccountLogin() async -> OAuthStartResponse {
        do {
            return try await api.startOAuthLogin()
        } catch {
            return OAuthStartResponse(ok: false, sessionId: nil, authUrl: nil, expiresIn: nil, error: error.localizedDescription)
        }
    }

    func finishOAuthAccountLogin(sessionId: String, code: String, label: String, switchAfter: Bool) async -> (ok: Bool, message: String) {
        let epoch = instanceEpoch
        do {
            let res = try await api.finishOAuthLogin(sessionId: sessionId, code: code, label: label, switchAfter: switchAfter)
            guard epoch == instanceEpoch else { return (false, "已切换服务器实例") }
            guard res.ok != false else {
                return (false, res.error ?? "授权换票失败")
            }
            await refreshAccounts(withQuota: true, force: true, forEpoch: epoch)
            if switchAfter {
                async let m: Void = refreshModels(force: true, forEpoch: epoch)
                async let q: Void = prefetchQuotaForWidget(force: true, forEpoch: epoch)
                _ = await (m, q)
            }
            let email = res.account?.email ?? "新账号"
            let action = res.updatedExisting == true ? "已更新凭证" : "已登录绑定"
            let msg = "\(action)：\(email)"
            showToast(msg)
            return (true, msg)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func cancelOAuthAccountLogin(sessionId: String) async {
        await api.cancelOAuthLogin(sessionId: sessionId)
    }

    /// 遇到 429 额度耗尽时：直接切换至其他有余量的 Google 账号，并在原会话上下文中无缝续接执行
    func resumeInterruptedSession(switchingToAccount acct: AgyAccountItem) async {
        guard !isCurrentTaskRunning else {
            showToast("当前会话已在执行中")
            return
        }
        let ok = await switchAccount(to: acct, silent: true)
        guard ok else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showToast("已切换至 \(acct.displayLabel)，正在续接执行…")
        draft = "已切换为账号 \(acct.displayLabel)（\(currentModelName)），请无缝续接继续执行未完成的任务"
        await send(resume: true)
    }
}
