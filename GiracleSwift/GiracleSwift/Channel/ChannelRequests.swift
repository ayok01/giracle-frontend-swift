import Foundation

/// `/channel/get-history/:channelId` に送る内容
struct HistoryRequest: Encodable {
    enum Direction: String, Encodable {
        case older, newer
    }

    var fetchLength = 30
    let fetchDirection: Direction
    /// 基準にするメッセージ。nil なら最新から（JSON には含めない）
    let messageIdFrom: String?

    init(direction: Direction, messageIdFrom: String? = nil) {
        self.fetchDirection = direction
        self.messageIdFrom = messageIdFrom
    }
}

/// `/message/send` に送る内容
struct SendRequest: Encodable {
    let channelId: String
    let message: String
    /// 返信先。nil なら JSON に含めない
    let replyingMessageId: String?
    /// 添付ファイル。nil なら JSON に含めない
    let fileIds: [String]?
}

/// `/message/edit` に送る内容
struct EditRequest: Encodable {
    let messageId: String
    let message: String
}

/// `/message/emoji-reaction` と `/message/delete-emoji-reaction` に送る内容
struct ReactionRequest: Encodable {
    let messageId: String
    let channelId: String
    let emojiCode: String
}

/// /message/file/upload の data。
/// バックエンドは insertFile の `.returning({ id })` をそのまま返すので `{ "fileId": { "id": "…" } }` の形になる
/// （Web 版も result.data.fileId.id で取り出している）
struct UploadedFile: Decodable {
    struct FileId: Decodable {
        let id: String
    }

    private let fileId: FileId

    var id: String { fileId.id }
}
