import SwiftUI

/// メッセージを一覧で見せるときの1行（受信箱・検索結果で共通）
struct MessageSummaryRow: View {
    let message: Message
    let user: User?
    let channelName: String
    let text: AttributedString
    let iconURL: URL?
    /// 上に出すラベル（受信箱の「メンション」「返信」など）
    var label: (title: String, systemImage: String)?
    /// 日付も出すか（検索結果は昔のメッセージも並ぶので日付を出す）
    var showsDate = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PresenceIcon(userId: message.userId, url: iconURL)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let label {
                        Label(label.title, systemImage: label.systemImage)
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                    }
                    Text(channelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Group {
                        if showsDate {
                            Text(message.createdAt, format: .dateTime.year().month().day().hour().minute())
                        } else {
                            Text(message.createdAt, format: .dateTime.hour().minute())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(user?.name ?? "…")
                    .font(.subheadline.bold())
                if !message.content.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .lineLimit(3)
                }
                if let files = message.files, !files.isEmpty {
                    Label("\(files.count)件の添付ファイル", systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
