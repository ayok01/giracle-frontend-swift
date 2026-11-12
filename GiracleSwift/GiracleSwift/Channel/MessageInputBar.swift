import SwiftUI

/// 入力欄の上に出す「返信中」「編集中」の表示
struct InputBanner {
    let systemImage: String
    let title: String
    /// 返信先・編集元の本文の抜粋
    let excerpt: String
}

/// 画面下に浮かぶメッセージ入力欄
struct MessageInputBar: View {
    @Binding var text: String
    let isSending: Bool
    var banner: InputBanner?
    /// 外からキーボードを出し入れするためのフォーカス（ref.focus() 相当）
    var focus: FocusState<Bool>.Binding
    var onCancelBanner: () -> Void = {}
    let onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        // 近くにあるガラス同士をなじませて1つの塊に見せる
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 8) {
                if let banner {
                    HStack(spacing: 8) {
                        Image(systemName: banner.systemImage)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(banner.title)
                                .font(.caption.bold())
                            Text(banner.excerpt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("取り消す", systemImage: "xmark", action: onCancelBanner)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(alignment: .bottom, spacing: 8) {
                    // axis: .vertical で、長文なら縦に伸びる（最大6行）
                    TextField("メッセージを入力", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .focused(focus)
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
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .animation(.snappy, value: banner?.title)
    }
}

#Preview {
    @Previewable @State var text = ""
    @Previewable @FocusState var isFocused: Bool
    VStack {
        Spacer()
        MessageInputBar(
            text: $text,
            isSending: false,
            banner: InputBanner(systemImage: "arrowshape.turn.up.left", title: "ian さんに返信", excerpt: "こんにちは"),
            focus: $isFocused
        ) {}
    }
}
