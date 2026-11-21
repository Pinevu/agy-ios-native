import Foundation

/// 定时 Cron 任务中心与 Skills 技能商店状态操作
extension AppState {

    // MARK: - 定时任务

    func refreshJobs() async {
        isLoadingJobs = true
        defer { isLoadingJobs = false }
        if let list = try? await api.jobs() {
            jobs = list
        }
    }

    func saveJob(
        id: String? = nil,
        name: String,
        cron: String,
        prompt: String,
        model: String?,
        enabled: Bool = true
    ) async -> String? {
        do {
            _ = try await api.upsertJob(
                id: id,
                name: name,
                cron: cron,
                prompt: prompt,
                model: model,
                enabled: enabled
            )
            await refreshJobs()
            showToast(id == nil ? "已创建定时任务" : "已更新定时任务")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func toggleJob(_ job: ScheduledJob) async {
        do {
            let updated = try await api.toggleJob(job.id)
            if let i = jobs.firstIndex(where: { $0.id == updated.id }) {
                jobs[i] = updated
            }
            showToast(updated.enabled ? "已启用「\(updated.name)」" : "已暂停「\(updated.name)」")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func runJobNow(_ job: ScheduledJob) async -> String? {
        do {
            let tid = try await api.runJob(job.id)
            showToast("已触发执行「\(job.name)」")
            await refreshJobs()
            await syncRunning()
            return tid
        } catch {
            showToast("触发失败：\(error.localizedDescription)")
            return nil
        }
    }

    func deleteJob(_ job: ScheduledJob) async {
        do {
            try await api.deleteJob(job.id)
            jobs.removeAll { $0.id == job.id }
            showToast("已删除定时任务")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    // MARK: - 技能与社区市场

    func refreshSkills() async {
        if let list = try? await api.skills() {
            skills = list
        }
    }

    func refreshSkillsCatalog(force: Bool = false) async {
        if let resp = try? await api.skillsCatalog(force: force), let list = resp.skills {
            skillsCatalog = list
        }
    }

    func installSkill(name: String? = nil, url: String? = nil, content: String? = nil) async -> String? {
        do {
            let resp = try await api.installSkill(name: name, url: url, content: content)
            if resp.ok == true {
                await refreshSkills()
                await refreshSkillsCatalog()
                showToast("已安装技能 \(resp.name ?? "")")
                return nil
            }
            return resp.error ?? "安装失败"
        } catch {
            return error.localizedDescription
        }
    }
}
