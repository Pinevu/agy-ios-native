import WidgetKit
import SwiftUI
import UIKit
import ActivityKit

@main
struct AgyWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgyLiveActivity()
        AgyRecentSessionsWidget()
        AgyQuickActionsWidget()
        AgyQuotaWidget()
    }
}

// MARK: - iOS 16.2 / 17+ Widget 容器背景兼容

private extension View {
    @ViewBuilder
    func agyWidgetBackground<BG: View>(_ background: BG) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(for: .widget) { background }
        } else {
            self.padding(14).background(background)
        }
    }
}

// MARK: - 1. 灵动岛与锁屏实时活动（零轮询原生计时）

struct AgyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgyActivityAttributes.self) { context in
            let s = context.state
            HStack(spacing: 12) {
                statusLogo(s)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(displayTitle(s))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .lineLimit(1)
                        if s.subagentCount > 0 && !s.privacyMode {
                            Text("+\(s.subagentCount)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange, in: Capsule())
                        }
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(s.running ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Text(displayStep(s))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.black.opacity(0.62))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                timerLabel(s, color: Color.black.opacity(0.65), size: 12.5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .widgetURL(deepLink(for: context.attributes.sessionKey))
            .activityBackgroundTint(Color.white.opacity(0.94))
            .activitySystemActionForegroundColor(.black)

        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusLogo(s)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timerLabel(s, color: .secondary, size: 13)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(displayTitle(s))
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(s.running ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Text(displayStep(s))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if s.subagentCount > 0 && !s.privacyMode {
                            Text("并发 \(s.subagentCount + 1)")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                statusLogo(s)
            } compactTrailing: {
                timerLabel(s, color: s.running ? .orange : .green, size: 12)
                    .frame(maxWidth: 44, alignment: .trailing)
            } minimal: {
                statusLogo(s)
            }
            .widgetURL(deepLink(for: context.attributes.sessionKey))
            .keylineTint(s.running ? .orange : .green)
        }
    }

    private func displayTitle(_ s: AgyActivityAttributes.ContentState) -> String {
        if s.privacyMode { return "Antigravity" }
        return s.title.isEmpty ? "Antigravity" : s.title
    }

    private func displayStep(_ s: AgyActivityAttributes.ContentState) -> String {
        if s.privacyMode { return s.running ? "任务执行中…" : "任务已完成" }
        return s.step.isEmpty ? (s.running ? "正在思考…" : "已完成") : s.step
    }

    private func deepLink(for sessionKey: String) -> URL? {
        if sessionKey.isEmpty || sessionKey.hasPrefix("draft-") {
            return URL(string: "antigravity://open")
        }
        return URL(string: "antigravity://session/\(sessionKey)")
    }

    @ViewBuilder
    private func timerLabel(_ s: AgyActivityAttributes.ContentState, color: Color, size: CGFloat) -> some View {
        if s.running {
            Text(s.startedAt, style: .timer)
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            let sec = max(0, s.finalElapsed ?? Int(Date().timeIntervalSince(s.startedAt)))
            Text(formatSeconds(sec))
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func statusLogo(_ s: AgyActivityAttributes.ContentState) -> some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if !s.running {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                        .background(Circle().fill(.black).padding(1))
                }
            }
    }

    private func formatSeconds(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : "\(s)s"
    }
}

// MARK: - 共享 TimelineProvider

struct AgySnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: AgySharedSnapshot
}

struct AgySnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgySnapshotEntry {
        AgySnapshotEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (AgySnapshotEntry) -> Void) {
        completion(AgySnapshotEntry(date: Date(), snapshot: AgySharedStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgySnapshotEntry>) -> Void) {
        let entry = AgySnapshotEntry(date: Date(), snapshot: AgySharedStore.load())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - 2. 最近会话小组件

struct AgyRecentSessionsWidget: Widget {
    let kind = "AgyRecentSessionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgySnapshotProvider()) { entry in
            AgyRecentSessionsWidgetView(snapshot: entry.snapshot)
                .agyWidgetBackground(Color(.systemBackground))
        }
        .configurationDisplayName("最近对话")
        .description("快速查看运行状态并直达最近对话")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct AgyRecentSessionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: AgySharedSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(snapshot.instanceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if snapshot.runningCount > 0 {
                    Text("运行 \(snapshot.runningCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange, in: Capsule())
                }
            }

            if snapshot.recentSessions.isEmpty {
                Spacer(minLength: 0)
                Text("打开 Antigravity 同步最近对话")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                let limit = family == .systemSmall ? 2 : 3
                ForEach(snapshot.recentSessions.prefix(limit)) { item in
                    Link(destination: URL(string: "antigravity://session/\(item.id)")!) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.running ? Color.orange : (item.unread ? Color.blue : Color.secondary.opacity(0.35)))
                                .frame(width: 6, height: 6)
                            Text(item.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(URL(string: "antigravity://open"))
    }
}

// MARK: - 3. 快捷启动小组件

struct AgyQuickActionsWidget: Widget {
    let kind = "AgyQuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgySnapshotProvider()) { entry in
            AgyQuickActionsWidgetView(snapshot: entry.snapshot)
                .agyWidgetBackground(Color(.systemBackground))
        }
        .configurationDisplayName("快捷入口")
        .description("一键新对话、语音提问、定时任务与技能商店")
        .supportedFamilies([.systemMedium])
    }
}

private struct AgyQuickActionsWidgetView: View {
    let snapshot: AgySharedSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text("Antigravity")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                Text(snapshot.runningCount > 0 ? "⚡ \(snapshot.runningCount) 运行中" : snapshot.instanceName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                actionTile("新对话", icon: "square.and.pencil", color: .blue, url: "antigravity://new")
                actionTile("语音", icon: "mic.fill", color: .orange, url: "antigravity://voice")
                actionTile("定时", icon: "clock.badge.checkmark", color: .purple, url: "antigravity://jobs")
                actionTile("技能", icon: "square.grid.2x2.fill", color: .green, url: "antigravity://skills")
            }
        }
    }

    private func actionTile(_ title: String, icon: String, color: Color, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - 4. 配额概览小组件（含锁屏圆形/矩形）

struct AgyQuotaWidget: Widget {
    let kind = "AgyQuotaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgySnapshotProvider()) { entry in
            AgyQuotaWidgetView(snapshot: entry.snapshot)
                .agyWidgetBackground(Color(.systemBackground))
        }
        .configurationDisplayName("用量与运行态")
        .description("在桌面或锁屏一眼查看剩余用量")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

private struct AgyQuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: AgySharedSnapshot

    private var pct: Double {
        max(0, min(1, snapshot.quotaPrimary?.remaining ?? 1.0))
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: pct) {
                Text("AGY")
            } currentValueLabel: {
                Text("\(Int(pct * 100))")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            .gaugeStyle(.accessoryCircular)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Antigravity")
                    .font(.system(size: 12, weight: .semibold))
                if let q = snapshot.quotaPrimary {
                    Text("\(q.label) · 剩余 \(Int(pct * 100))%")
                        .font(.system(size: 11))
                        .lineLimit(1)
                } else {
                    Text(snapshot.runningCount > 0 ? "\(snapshot.runningCount) 个任务运行中" : "已就绪")
                        .font(.system(size: 11))
                }
            }

        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Spacer()
                    Text(snapshot.quotaPlan ?? "Antigravity")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let q = snapshot.quotaPrimary {
                    Text("\(Int(pct * 100))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(pct < 0.2 ? .red : (pct < 0.5 ? .orange : .green))
                    Text(q.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(snapshot.runningCount > 0 ? "\(snapshot.runningCount) 运行中" : "就绪")
                        .font(.system(size: 20, weight: .bold))
                    Text(snapshot.instanceName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .widgetURL(URL(string: "antigravity://quota"))
        }
    }
}
