import Foundation

/// WebSocket で届くイベント（今対応しているものだけ）
enum RealtimeEvent {
    /// 接続できた（つなぎ直しのときも届く）
    case connected
    case messageSent(Message)
    /// URL プレビューの更新などで、メッセージ全体が届いた
    case messageUpdated(Message)
    /// 編集で、本文などの一部だけが届いた
    case messageEdited(MessageEdit)
    case messageDeleted(messageId: String, channelId: String)
    case reactionAdded(Reaction)
    case reactionDeleted(Reaction)
    /// 受信箱に通知が増えた / 既読で消えた / 全部消えた
    case inboxAdded(InboxItem)
    case inboxDeleted(messageId: String)
    case inboxCleared
    /// 自分の既読時刻が更新された（他の端末で読んだときも届く）
    case readTimeUpdated(channelId: String)
}

extension RealtimeEvent {
    /// `{ "signal": "...", "data": ... }` を読み取る。知らない signal なら nil
    static func decode(_ text: String) -> RealtimeEvent? {
        let json = Data(text.utf8)
        let decoder = JSONDecoder.giracle()

        // まず signal だけ読んで、data の形を決める
        guard let signal = try? decoder.decode(Signal.self, from: json).signal else { return nil }

        switch signal {
        case "message::SendMessage":
            return (try? decoder.decode(Payload<Message>.self, from: json)).map { .messageSent($0.data) }
        case "message::UpdateMessage":
            // 同じ signal でも、メッセージ全体が来る場合と編集の一部だけが来る場合がある。
            // まず全体として読み、だめなら編集の形で読む
            if let full = try? decoder.decode(Payload<Message>.self, from: json) {
                return .messageUpdated(full.data)
            }
            return (try? decoder.decode(Payload<MessageEdit>.self, from: json)).map { .messageEdited($0.data) }
        case "message::MessageDeleted":
            return (try? decoder.decode(Payload<MessageDeleted>.self, from: json)).map {
                .messageDeleted(messageId: $0.data.messageId, channelId: $0.data.channelId)
            }
        case "message::AddReaction":
            return (try? decoder.decode(Payload<Reaction>.self, from: json)).map { .reactionAdded($0.data) }
        case "message::DeleteReaction":
            return (try? decoder.decode(Payload<Reaction>.self, from: json)).map { .reactionDeleted($0.data) }
        case "inbox::Added":
            return (try? decoder.decode(Payload<InboxAddedPayload>.self, from: json)).map { .inboxAdded($0.data.item) }
        case "inbox::Deleted":
            return (try? decoder.decode(Payload<InboxDeleted>.self, from: json)).map { .inboxDeleted(messageId: $0.data.messageId) }
        case "inbox::Clear":
            return .inboxCleared
        case "message::ReadTimeUpdated":
            return (try? decoder.decode(Payload<ReadTimeUpdated>.self, from: json)).map {
                .readTimeUpdated(channelId: $0.data.channelId)
            }
        default:
            return nil
        }
    }
}

private struct InboxDeleted: Decodable {
    let messageId: String
}

private struct ReadTimeUpdated: Decodable {
    let channelId: String
}

private struct Signal: Decodable {
    let signal: String
}

private struct Payload<T: Decodable>: Decodable {
    let data: T
}

private struct MessageDeleted: Decodable {
    let messageId: String
    let channelId: String
}
