import SwiftUI

struct LoginView: View {
    @EnvironmentObject var state: AppState
    @State private var password = ""
    @State private var showPassword = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)

                    // Logo
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.10), radius: 10, y: 2)
                        .padding(.bottom, 22)

                    Text("Antigravity")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.bottom, 24)

                    // 密码框
                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("请输入密码", text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("请输入密码", text: $password)
                            }
                        }
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { submit() }

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(focused ? Color.accentColor : Color(.separator).opacity(0.5), lineWidth: 1)
                    )

                    if let err = state.loginError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }

                    Button(action: submit) {
                        ZStack {
                            if state.isLoggingIn {
                                ProgressView().tint(.white)
                            } else {
                                Text("登 录").font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(state.isLoggingIn || password.isEmpty)
                    .padding(.top, 18)

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 380)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty, !state.isLoggingIn else { return }
        focused = false
        Task { await state.login(password) }
    }
}
