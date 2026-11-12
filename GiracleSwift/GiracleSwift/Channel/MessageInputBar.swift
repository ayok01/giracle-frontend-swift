import SwiftUI

/// 画面下に浮かぶメッセージ入力欄
struct MessageInputBar: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        // 近くにあるガラス同士をなじませて1つの塊に見せる
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 8) {
                // axis: .vertical で、長文なら縦に伸びる（最大6行）
                TextField("メッセージを入力", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.body.bold())
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

#Preview {
    @Previewable @State var text = ""
    VStack {
        Spacer()
        MessageInputBar(text: $text, isSending: false) {}
    }
}
