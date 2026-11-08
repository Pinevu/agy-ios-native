import WidgetKit
import SwiftUI
import ActivityKit

@main
struct AgyWidgetBundle: WidgetBundle {
    var body: some Widget {
        AgyLiveActivity()
    }
}

struct AgyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgyActivityAttributes.self) { context in
            // 锁屏 / 通知中心
            HStack(spacing: 12) {
                statusDot(context.state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.title.isEmpty ? "Antigravity" : context.state.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(context.state.step)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(timeText(context.state.elapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    statusDot(context.state)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timeText(context.state.elapsed))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title.isEmpty ? "Antigravity" : context.state.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Image(systemName: context.state.running ? "ellipsis" : "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(context.state.running ? Color.orange : Color.green)
                        Text(context.state.step)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                statusDot(context.state)
            } compactTrailing: {
                Text(timeText(context.state.elapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            } minimal: {
                statusDot(context.state)
            }
            .keylineTint(context.state.running ? .orange : .green)
        }
    }

    @ViewBuilder
    private func statusDot(_ s: AgyActivityAttributes.ContentState) -> some View {
        if s.running {
            ProgressView()
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
        }
    }

    private func timeText(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return m > 0 ? String(format: "%d:%02d", m, s) : "\(s)s"
    }
}
