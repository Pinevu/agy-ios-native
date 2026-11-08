import SwiftUI

/// 按压态：点击瞬间轻微缩小，给「点到了」的反馈
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 行高缓存：滚动时已测量过的行直接用缓存高度，
/// 避免 LazyVStack 反复重排导致的跳动和掉帧
private final class RowHeightStore {
    static let shared = RowHeightStore()
    var heights: [UUID: CGFloat] = [:]
}

private struct HeightCacheModifier: ViewModifier {
    let id: UUID
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onAppear { height = RowHeightStore.shared.heights[id] ?? 0 }
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { store(g.size.height) }
                        .onChange(of: g.size.height) { h in store(h) }
                }
            )
            .frame(minHeight: height > 0 ? height : nil, alignment: .top)
    }

    private func store(_ h: CGFloat) {
        guard h > 1, abs(h - height) > 0.5 else { return }
        height = h
        RowHeightStore.shared.heights[id] = h
    }
}

extension View {
    /// 缓存行高，长会话滚动时减少重排
    func heightCached(_ id: UUID) -> some View {
        modifier(HeightCacheModifier(id: id))
    }
}
