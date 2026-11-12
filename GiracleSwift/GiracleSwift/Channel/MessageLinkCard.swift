import SwiftUI

/// メッセージリンク先の表示に使う内容
struct LinkedMessagePreview: Identifiable {
    let ref: MessageLinkRef
    /// 取れたリンク先のメッセージ（読み込み中・取れなかったときは nil）
    let message: Message?
    /// 削除された・見る権限がないなどで取れなかった
    let isUnavailable: Bool
    let userName: String?
    let channelName: String
    let text: AttributedString?
    let iconURL: URL?

    var id: MessageLinkRef { ref }
}

/// メッセージリンク先のカード（Web 版の MessageLinkPreview に相当）。タップでそのメッセージへ移動
struct MessageLinkCard: View {
    let preview: LinkedMessagePreview
    let onOpen: () -> Void

    var body: some View {
        if preview.isUnavailable {
            Label("削除されたか、表示できないメッセージ", systemImage: "nosign")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        UserIcon(url: preview.iconURL, size: 20)
                        Text(preview.userName ?? "…")
                            .font(.caption.bold())
                        Text("・#\(preview.channelName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    if let message = preview.message {
                        if let text = preview.text, !message.content.isEmpty {
                            Text(text)
                                .font(.subheadline)
                                .lineLimit(4)
                        }
                        if let files = message.files, !files.isEmpty {
                            Label("\(files.count)件の添付ファイル", systemImage: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: 300, alignment: .leading)
                // 左に縦線を引いて「引用」っぽく
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.tint)
                        .frame(width: 3)
                }
                .background(.fill.quaternary)
                .clipShape(.rect(cornerRadius: 10))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}
