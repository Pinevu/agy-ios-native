import SwiftUI
import UIKit

final class AgyAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        LiveActivityManager.terminateAllActivitiesSync()
    }
}

@main
struct AgyApp: App {
    @UIApplicationDelegateAdaptor(AgyAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var router = DeepLinkRouter.shared
    @StateObject private var appLock = AppLockManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(router)
                .environmentObject(appLock)
                .preferredColorScheme(state.colorScheme)
                .onOpenURL { url in
                    router.handle(url: url)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var loaded = false

    var body: some View {
        ZStack {
            Group {
                if state.isBooting {
                    splash
                } else if state.isLoggedIn {
                    ChatView()
                } else {
                    LoginView()
                }
            }

            if appLock.isLocked {
                AppLockOverlay()
                    .transition(.opacity)
                    .zIndex(99)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)
        .task {
            guard !loaded else { return }
            loaded = true
            await state.bootstrap()
            state.startRunningPoller()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                appLock.lockIfNeeded()
                state.appEnteredBackground()
                return
            }
            guard phase == .active, loaded, state.isLoggedIn else { return }
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
