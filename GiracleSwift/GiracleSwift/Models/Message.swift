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

    enum CodingKeys: String, CodingKey {
        case id, content, isSystemMessage, isEdited, userId, channelId, createdAt, replyingMessageId
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
