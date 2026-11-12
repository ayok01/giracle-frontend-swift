import SwiftUI
import PhotosUI

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
    /// 送信前の添付画像
    var attachments: [PendingAttachment] = []
    /// 写真が選ばれた（nil なら写真ボタンを出さない。編集中など）
    var onPickPhotos: (([PhotosPickerItem]) -> Void)?
    var onRemoveAttachment: (PendingAttachment) -> Void = { _ in }
    /// "@" 入力中に出すメンションの候補
    var mentionCandidates: [User] = []
    var iconURL: (String) -> URL? = { _ in nil }
    var onSelectMention: (User) -> Void = { _ in }
    let onSend: () -> Void

    /// 写真アプリで選んだもの。選ばれたら親に渡してすぐ空にする
    @State private var photoItems: [PhotosPickerItem] = []

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !isSending
    }

    var body: some View {
        // 近くにあるガラス同士をなじませて1つの塊に見せる
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 8) {
                if !mentionCandidates.isEmpty {
                    mentionList
                }

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

                if !attachments.isEmpty {
                    attachmentPreviews
                }

                HStack(alignment: .bottom, spacing: 8) {
                    if let onPickPhotos {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: 4, matching: .images) {
                            Image(systemName: "photo")
                                .font(.body.bold())
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .onChange(of: photoItems) { _, items in
                            guard !items.isEmpty else { return }
                            onPickPhotos(items)
                            photoItems = []
                        }
                    }

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
        .animation(.snappy, value: attachments.map(\.id))
        .animation(.snappy, value: mentionCandidates.map(\.id))
    }

    /// メンションの候補。タップで入力欄に "@名前" が入る
    private var mentionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(mentionCandidates) { user in
                    Button {
                        onSelectMention(user)
                    } label: {
                        HStack(spacing: 10) {
                            UserIcon(url: iconURL(user.id), size: 28)
                            Text(user.name ?? "")
                                .lineLimit(1)
                            if user.isBot {
                                Text("BOT")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // 候補が多いときは 4 件分ほどの高さでスクロール
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 送信前の画像を横に並べる。右上の × で外せる
    private var attachmentPreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachment.thumbnail
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay(alignment: .topTrailing) {
                            Button("外す", systemImage: "xmark.circle.fill") {
                                onRemoveAttachment(attachment)
                            }
                            .labelStyle(.iconOnly)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .padding(4)
                        }
                }
            }
            .padding(8)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
