import Foundation

/// `/user/info/:id` が返すユーザー（今使う項目だけ）
struct User: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let isBot: Bool
    let selfIntroduction: String?
    let isBanned: Bool?
    /// 参加しているチャンネル
    let channelJoins: [ChannelJoin]?
    /// 付与されているロール
    let roleLinks: [RoleLink]?

    struct ChannelJoin: Decodable, Hashable {
        let channelId: String
    }

    struct RoleLink: Decodable, Hashable {
        let roleId: String
    }

    // JSON のキー名と Swift のプロパティ名が違うときは対応表を書く
    enum CodingKeys: String, CodingKey {
        case id, name, isBot, selfIntroduction, isBanned
        case channelJoins = "ChannelJoin"
        case roleLinks = "RoleLink"
    }
}

extension User {
    /// user::ProfileUpdate で届いた情報を反映した User を返す。
    /// 通知にはロールや参加チャンネルが入っていないので、それらは今のものを残す
    func updated(with update: User) -> User {
        User(
            id: id,
            name: update.name,
            isBot: update.isBot,
            selfIntroduction: update.selfIntroduction,
            isBanned: update.isBanned ?? isBanned,
            channelJoins: update.channelJoins ?? channelJoins,
            roleLinks: update.roleLinks ?? roleLinks
        )
    }
}

/// `/role/list` のロール
struct Role: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    /// "#ff8800" のような色
    let color: String
}
