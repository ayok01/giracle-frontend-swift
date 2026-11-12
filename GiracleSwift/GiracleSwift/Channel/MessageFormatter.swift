import SwiftUI

/// メッセージ本文を、メンションやリンクに色を付けた AttributedString に変換する。
/// Web 版の MessageTextRender.tsx と同じ記法に対応する:
///   URL / @<userId> / #<channelId> / &<channelId:messageId> / `code`
struct MessageFormatter {
    let users: [String: User]
    let channels: [String: Channel]
    let myUserId: String?

    func format(_ content: String) -> AttributedString {
        let pattern = #/(?<url>https?://[-A-Za-z0-9+&@#/%?=~_|!:,.;]*[-A-Za-z0-9+&@#/%=~_|])|@<(?<mention>[a-f0-9-]+)>|#<(?<channel>[a-f0-9-]+)>|&<(?<linkChannel>[a-f0-9-]+):(?<linkMessage>[a-f0-9-]+)>|`(?<code>[^`]+)`/#

        var result = AttributedString()
        var lastIndex = content.startIndex

        // マッチの手前の普通の文字 → マッチ部分 → … の順に足していく
        for match in content.matches(of: pattern) {
            result += AttributedString(String(content[lastIndex..<match.range.lowerBound]))

            let output = match.output
            if let url = output.url {
                result += link(String(url))
            } else if let userId = output.mention {
                result += mention(String(userId))
            } else if let channelId = output.channel {
                result += channelName(String(channelId))
            } else if let channelId = output.linkChannel, let messageId = output.linkMessage {
                result += messageLink(MessageLinkRef(channelId: String(channelId), messageId: String(messageId)))
            } else if let code = output.code {
                result += inlineCode(String(code))
            }

            lastIndex = match.range.upperBound
        }
        result += AttributedString(String(content[lastIndex...]))
        return result
    }

    private func link(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        // .link を付けると Text 上でタップでき、Safari で開く
        s.link = URL(string: text)
        return s
    }

    private func mention(_ userId: String) -> AttributedString {
        let name = users[userId]?.name ?? "不明なユーザー"
        var s = AttributedString("@\(name)")
        s.font = .body.bold()
        // タップでプロフィールを開けるよう、アプリ内だけで使う URL を付ける（ChannelView の openURL で受け取る）
        s.link = Self.profileURL(for: userId)
        s.backgroundColor = userId == myUserId ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.2)
        return s
    }

    /// プロフィールを開くためのアプリ内 URL（"giracle-user:ユーザーId"）
    static func profileURL(for userId: String) -> URL? {
        URL(string: "giracle-user:\(userId)")
    }

    /// アプリ内 URL ならユーザーIdを取り出す
    static func userId(fromProfileURL url: URL) -> String? {
        guard url.scheme == "giracle-user" else { return nil }
        return url.absoluteString.replacing("giracle-user:", with: "")
    }

    private func channelName(_ channelId: String) -> AttributedString {
        let name = channels[channelId]?.name ?? "不明なチャンネル"
        var s = AttributedString("#\(name)")
        s.font = .body.bold()
        return s
    }

    /// Web 版と同じく「#チャンネル名 のメッセージ」。タップで移動できるようアプリ内 URL を付ける
    private func messageLink(_ ref: MessageLinkRef) -> AttributedString {
        var name = channels[ref.channelId]?.name ?? "不明なチャンネル"
        if name.count > 18 {
            name = String(name.prefix(18)) + "…"
        }
        var s = AttributedString("#\(name) のメッセージ")
        s.font = .body.bold()
        s.backgroundColor = Color.gray.opacity(0.2)
        s.link = ref.url
        return s
    }

    private func inlineCode(_ code: String) -> AttributedString {
        var s = AttributedString(code)
        s.font = .body.monospaced()
        s.backgroundColor = Color.gray.opacity(0.2)
        return s
    }
}
