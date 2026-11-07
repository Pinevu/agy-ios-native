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
    @State private var loaded = false

    var body: some View {
        Group {
            if state.isLoggedIn {
                ChatView()
            } else {
                LoginView()
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await state.bootstrap()
        }
    }
}
