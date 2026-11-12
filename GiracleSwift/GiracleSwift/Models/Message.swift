import Foundation

/// `/channel/get-history` などが返すメッセージ
struct Message: Decodable, Identifiable, Hashable {
    let id: String
    let content: String
    let isSystemMessage: Bool
    let isEdited: Bool
    let userId: String
    let channelId: String
    let createdAt: Date
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
}
