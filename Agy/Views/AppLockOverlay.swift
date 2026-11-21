import SwiftUI

/// 可选生物识别解锁蒙层（参考 OpenMinis AppLockOverlay）
struct AppLockOverlay: View {
    @EnvironmentObject var appLock: AppLockManager

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.10), radius: 12, y: 3)

                Text("Antigravity 已锁定")
                    .font(.system(size: 20, weight: .bold))

                if let err = appLock.errorText {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await appLock.unlock() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: appLock.biometryIcon)
                            .font(.system(size: 17, weight: .semibold))
                        Text("使用 \(appLock.biometryTitle) 解锁")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .frame(height: 48)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, 8)
            }
            .padding(32)
        }
        .task {
            await appLock.unlock()
        }
    }
}
