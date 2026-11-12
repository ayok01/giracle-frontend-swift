import SwiftUI

/// 返信先の表示内容
struct ReplyPreview {
    let name: String?
    let excerpt: String
}

/// メッセージ1件分の表示
struct MessageRow: View {
    let message: Message
    let text: AttributedString
    let user: User?
    let iconURL: URL?
    let reply: ReplyPreview?
    let imageDimensions: [String: ImageDimension]
    let baseURL: URL?
    let linkPreviews: [LinkedMessagePreview]
    var onToggleReaction: (String) -> Void = { _ in }
    var onTapUser: () -> Void = {}
    var onTapReply: () -> Void = {}
    var onOpenLink: (MessageLinkRef) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply {
                ReplyQuote(reply: reply)
                    // アイコンの右側（本文の位置）にそろえる
                    .padding(.leading, 46)
                    // タップで返信先のメッセージへ移動
                    .contentShape(.rect)
                    .onTapGesture(perform: onTapReply)
            }
            content
        }
        // 文字の無い余白部分を長押ししても反応するよう、行全体を触れる範囲にする
        .contentShape(.rect)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            // URLSession.shared を使うので Cookie も自動で送られる。タップでプロフィール
            PresenceIcon(userId: message.userId, url: iconURL)
                .onTapGesture(perform: onTapUser)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(user?.name ?? "…")
                        .font(.subheadline.bold())
                        .onTapGesture(perform: onTapUser)
                    Text(message.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if message.isEdited {
                        Text("(編集済み)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // 画像だけのメッセージは本文が空
                // 文字選択（textSelection）は長押しを奪ってしまうので付けない。コピーは長押しのシートから
                if !message.content.isEmpty {
                    Text(text)
                }
                MessageAttachments(message: message, imageDimensions: imageDimensions, baseURL: baseURL)
                // 本文中のメッセージリンク先の中身
                ForEach(linkPreviews) { preview in
                    MessageLinkCard(preview: preview) {
                        onOpenLink(preview.ref)
                    }
                }
                if let reactions = message.reactionSummary, !reactions.isEmpty {
                    ReactionBar(reactions: reactions, onToggle: onToggleReaction)
                }
            }
        }
    }
}

/// 返信先の引用（1行）
struct ReplyQuote: View {
    let reply: ReplyPreview

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption2)
            if let name = reply.name {
                Text(name)
                    .font(.caption.bold())
            }
            Text(reply.excerpt)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            // 左に縦線を引いて引用っぽく
            Capsule()
                .fill(.tertiary)
                .frame(width: 3)
        }
    }
}

/// 参加・退出などのお知らせ
struct SystemMessageRow: View {
    let content: SystemMessageContent
    let user: User?

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: .capsule)
            .frame(maxWidth: .infinity)
    }

    private var name: String { user?.name ?? "不明なユーザー" }

    private var text: String {
        switch content.messageTerm {
        case .welcome: "\(name)さんがGiracleに参加しました！ようこそ"
        case .channelJoin: "\(name)さんがチャンネルへ参加しました！"
        case .channelLeft: "\(name)さんがチャンネルを退出しました。"
        case .channelInvited: "\(name)さんが招待されました！"
        case .channelKicked: "\(name)さんがチャンネルからキックされました。"
        }
    }

    private var symbol: String {
        switch content.messageTerm {
        case .welcome: "hand.wave"
        case .channelJoin: "person.crop.circle.badge.plus"
        case .channelLeft: "rectangle.portrait.and.arrow.right"
        case .channelInvited: "envelope"
        case .channelKicked: "person.crop.circle.badge.xmark"
        }
    }
}
