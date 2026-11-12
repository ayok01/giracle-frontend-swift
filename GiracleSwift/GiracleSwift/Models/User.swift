import Foundation

/// `/user/info/:id` が返すユーザー（今使う項目だけ）
struct User: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let isBot: Bool
    /// 参加しているチャンネル
    let channelJoins: [ChannelJoin]?

    struct ChannelJoin: Decodable, Hashable {
        let channelId: String
    }

    // JSON のキー名と Swift のプロパティ名が違うときは対応表を書く
    enum CodingKeys: String, CodingKey {
        case id, name, isBot
        case channelJoins = "ChannelJoin"
    }
}
