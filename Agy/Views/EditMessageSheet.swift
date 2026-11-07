import SwiftUI

/// 编辑已发送的消息并覆盖重发
struct EditMessageSheet: View {
    let original: String
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text != original
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .focused($focused)

                Text("修改后将从这条消息起覆盖重新生成，之前该轮及之后的回复会被删除。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)

                Spacer(minLength: 0)

                Button {
                    onSubmit(text)
                } label: {
                    Text("重新生成")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(canSubmit ? Color.accentColor : Color.gray.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .background(Color(.systemBackground))
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
            }
            .onAppear {
                text = original
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
            }
        }
    }
}
