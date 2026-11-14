import SwiftUI

@main
struct AgyApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(state.colorScheme)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var loaded = false

    var body: some View {
        Group {
            if state.isBooting {
                // 校验令牌期间显示占位，避免已登录用户看到登录页一闪而过
                splash
            } else if state.isLoggedIn {
                ChatView()
            } else {
                LoginView()
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await state.bootstrap()
            state.startRunningPoller()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            // iOS 从后台回来会冻结旧 SSE；立即重新拉运行态并恢复轮询，
            // 不必再把 App 划掉重进才能看到正在执行的命令。
            Task { await state.appBecameActive() }
        }
    }

    private var splash: some View {
        VStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
