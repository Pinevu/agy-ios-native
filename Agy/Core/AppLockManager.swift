import Foundation
import LocalAuthentication

/// 可选生物识别应用锁（参考 OpenMinis AppLockOverlay；默认关闭，开启后切后台自动上锁）
@MainActor
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    private let enabledKey = "agy_app_lock_enabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: enabledKey) }
    }
    @Published var isLocked: Bool = false
    @Published var errorText: String?

    private init() {
        let on = UserDefaults.standard.bool(forKey: enabledKey)
        isEnabled = on
        isLocked = on
    }

    var biometryTitle: String {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            return "设备密码"
        }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "生物识别"
        }
    }

    var biometryIcon: String {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            return "lock.fill"
        }
        switch ctx.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }

    func lockIfNeeded() {
        if isEnabled {
            isLocked = true
            errorText = nil
        }
    }

    func unlock() async {
        errorText = nil
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "输入密码"
        var err: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
            ? .deviceOwnerAuthentication
            : .deviceOwnerAuthenticationWithBiometrics
        do {
            let ok = try await ctx.evaluatePolicy(policy, localizedReason: "解锁 Antigravity")
            if ok {
                isLocked = false
                errorText = nil
            }
        } catch {
            errorText = "验证未通过，请重试"
        }
    }

    func setEnabled(_ on: Bool) async -> Bool {
        if !on {
            isEnabled = false
            isLocked = false
            return true
        }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            errorText = "当前设备未设置密码或生物识别"
            return false
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "开启 Antigravity 应用锁")
            if ok {
                isEnabled = true
                isLocked = false
                return true
            }
        } catch {
            errorText = "验证取消"
        }
        return false
    }
}
