import Foundation

/// 「このチャンネルの、このメッセージ」を開くための行き先（受信箱やメッセージリンクから使う）
struct ChannelRoute: Hashable, Identifiable {
    let channel: Channel
    let messageId: String

    var id: String { "\(channel.id)/\(messageId)" }
}

/// 本文中のメッセージリンク `&<チャンネルId:メッセージId>`
struct MessageLinkRef: Hashable {
    let channelId: String
    let messageId: String

    /// タップで受け取るためのアプリ内 URL（"giracle-message:チャンネルId/メッセージId"）
    var url: URL? {
        URL(string: "giracle-message:\(channelId)/\(messageId)")
    }

    init(channelId: String, messageId: String) {
        self.channelId = channelId
        self.messageId = messageId
    }

    /// アプリ内 URL から戻す
    init?(url: URL) {
        guard url.scheme == "giracle-message" else { return nil }
        let parts = url.absoluteString.replacing("giracle-message:", with: "").split(separator: "/")
        guard parts.count == 2 else { return nil }
        self.init(channelId: String(parts[0]), messageId: String(parts[1]))
    }
}

extension Message {
    /// 本文中のメッセージリンク（重複は除く）
    var messageLinks: [MessageLinkRef] {
        var seen = Set<MessageLinkRef>()
        return content.matches(of: #/&<([a-f0-9-]+):([a-f0-9-]+)>/#).compactMap { match in
            let ref = MessageLinkRef(channelId: String(match.output.1), messageId: String(match.output.2))
            return seen.insert(ref).inserted ? ref : nil
        }
    }
}
