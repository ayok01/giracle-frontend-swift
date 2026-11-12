import Foundation

/// WebSocket で届くイベント（今対応しているものだけ）
enum RealtimeEvent {
    /// 接続できた（つなぎ直しのときも届く）
    case connected
    case messageSent(Message)
    /// 編集のほか、URL プレビューの更新でも届く
    case messageUpdated(Message)
    case messageDeleted(messageId: String, channelId: String)
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
            return (try? decoder.decode(Payload<Message>.self, from: json)).map { .messageUpdated($0.data) }
        case "message::MessageDeleted":
            return (try? decoder.decode(Payload<MessageDeleted>.self, from: json)).map {
                .messageDeleted(messageId: $0.data.messageId, channelId: $0.data.channelId)
            }
        default:
            return nil
        }
    }
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
