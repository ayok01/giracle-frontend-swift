import Foundation

/// `/channel/get-history` などが返すメッセージ
struct Message: Decodable, Identifiable, Hashable {
    let id: String
    /// 編集で書き換わるので var
    var content: String
    let isSystemMessage: Bool
    var isEdited: Bool
    let userId: String
    let channelId: String
    let createdAt: Date
    /// 返信先のメッセージId
    let replyingMessageId: String?
    /// 添付ファイル（API によっては含まれないので nil もありうる）
    let files: [MessageFile]?
    /// URL プレビュー（送信直後は空で、生成後に message::UpdateMessage で届く）
    let urlPreviews: [UrlPreview]?
    /// リアクションの集計（履歴取得時に含まれる。リアクションの増減で書き換わるので var）
    var reactionSummary: [ReactionSummary]?

    enum CodingKeys: String, CodingKey {
        case id, content, isSystemMessage, isEdited, userId, channelId, createdAt, replyingMessageId, reactionSummary
        case files = "MessageFileAttached"
        case urlPreviews = "MessageUrlPreview"
    }
}

/// 編集の結果。バックエンドの /message/edit とその WebSocket 通知は
/// メッセージの一部の項目しか返さない（createdAt などが無い）ので、別の型で受け取る
struct MessageEdit: Decodable {
    let id: String
    let channelId: String
    let content: String
    let isEdited: Bool
}

extension Message {
    /// 編集の結果を反映する
    mutating func apply(_ edit: MessageEdit) {
        content = edit.content
        isEdited = edit.isEdited
    }
}

/// 絵文字ごとのリアクション数
struct ReactionSummary: Decodable, Hashable {
    let emojiCode: String
    var count: Int
    var includingYou: Bool
}

/// リアクション1件（/message/emoji-reaction の返り値と、WebSocket の AddReaction / DeleteReaction）
struct Reaction: Decodable {
    let messageId: String
    let channelId: String
    let userId: String
    let emojiCode: String
}

extension Message {
    /// 自分が付けたリアクションの数（1メッセージ10個まで）
    var myReactionCount: Int {
        (reactionSummary ?? []).filter(\.includingYou).count
    }

    mutating func addReaction(_ reaction: Reaction, myUserId: String?) {
        var summary = reactionSummary ?? []
        let isMine = reaction.userId == myUserId
        if let index = summary.firstIndex(where: { $0.emojiCode == reaction.emojiCode }) {
            summary[index].count += 1
            summary[index].includingYou = summary[index].includingYou || isMine
        } else {
            summary.append(ReactionSummary(emojiCode: reaction.emojiCode, count: 1, includingYou: isMine))
        }
        reactionSummary = summary
    }

    mutating func removeReaction(_ reaction: Reaction, myUserId: String?) {
        guard var summary = reactionSummary,
              let index = summary.firstIndex(where: { $0.emojiCode == reaction.emojiCode })
        else { return }
        summary[index].count -= 1
        if reaction.userId == myUserId {
            summary[index].includingYou = false
        }
        if summary[index].count <= 0 {
            summary.remove(at: index)
        }
        reactionSummary = summary
    }
}

/// メッセージの添付ファイル
struct MessageFile: Decodable, Identifiable, Hashable {
    let id: String
    let actualFileName: String
    let size: Int
    /// MIME タイプ（"image/png" など）
    let type: String

    var isImage: Bool { type.hasPrefix("image/") }
}

/// URL プレビュー（OGP）
struct UrlPreview: Decodable, Identifiable, Hashable {
    let id: Int
    let url: String
    let title: String
    let description: String?
    let faviconLink: String?
    let imageLink: String?
    let videoLink: String?
}

/// 画像の縦横サイズ（履歴取得時に `ImageDimensions` として届く）
struct ImageDimension: Decodable, Hashable {
    let width: Double
    let height: Double
}

/// システムメッセージの content（JSON 文字列）の中身
struct SystemMessageContent: Decodable {
    enum Term: String, Decodable {
        case welcome = "WELCOME"
        case channelJoin = "CHANNEL_JOIN"
        case channelLeft = "CHANNEL_LEFT"
        case channelInvited = "CHANNEL_INVITED"
        case channelKicked = "CHANNEL_KICKED"
    }

    let targetUserId: String
    let messageTerm: Term
}

extension Message {
    /// システムメッセージなら content を読み取った結果
    var systemContent: SystemMessageContent? {
        guard isSystemMessage else { return nil }
        return try? JSONDecoder().decode(SystemMessageContent.self, from: Data(content.utf8))
    }

    /// 表示に必要なユーザーId（送信者・メンション先・システムメッセージの対象）
    var relatedUserIds: [String] {
        var ids = [userId]
        ids += content.matches(of: #/@<([a-f0-9-]+)>/#).map { String($0.output.1) }
        if let target = systemContent?.targetUserId {
            ids.append(target)
        }
        return ids
    }
}

/// `/channel/get-history/:channelId` の data
struct MessageHistory: Decodable {
    /// 新しい順
    let history: [Message]
    /// 最初（いちばん古いメッセージ）まで取得したか
    let atTop: Bool
    /// 最新まで取得したか
    let atEnd: Bool
    /// 画像ファイルId → 縦横サイズ。読み込む前から表示の高さを決めるのに使う
    let imageDimensions: [String: ImageDimension]?

    enum CodingKeys: String, CodingKey {
        case history, atTop, atEnd
        case imageDimensions = "ImageDimensions"
    }
}
