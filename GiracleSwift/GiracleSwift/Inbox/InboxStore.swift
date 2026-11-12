import Foundation
import Observation

/// 受信箱の1件（自分へのメンション・返信）
struct InboxItem: Identifiable, Hashable {
    enum Kind: String {
        case mention, reply
    }

    let kind: Kind
    let message: Message
    /// 通知された時刻
    let happenedAt: Date

    var id: String { message.id }
}

/// 受信箱の一覧を持つストア（どの画面からでも件数や既読を扱えるよう、アプリ全体で共有する）
@Observable
final class InboxStore {
    /// 新しい順
    private(set) var items: [InboxItem] = []

    func load(client: APIClient) async {
        guard let rows: [InboxRow] = try? await client.get("message/inbox") else { return }
        items = rows.map(\.item).sorted { $0.happenedAt > $1.happenedAt }
    }

    func contains(messageId: String) -> Bool {
        items.contains { $0.message.id == messageId }
    }

    /// 1件既読にする（一覧から消える）
    func read(messageId: String, client: APIClient) async {
        guard contains(messageId: messageId) else { return }
        items.removeAll { $0.message.id == messageId }
        try? await client.post("message/inbox/read", body: ["messageId": messageId])
    }

    /// チャンネルで表示されたメッセージのうち、受信箱にあるものを既読にする（Web 版の MentionReadWrapper と同じ）
    func readShown(messageIds: [String], client: APIClient) async {
        for id in messageIds where contains(messageId: id) {
            await read(messageId: id, client: client)
        }
    }

    func clear(client: APIClient) async throws {
        try await client.post("message/inbox/clear", body: [String: String]())
        items = []
    }

    /// WebSocket のイベントを反映する（他の端末で既読にした場合も届く）
    func apply(_ event: RealtimeEvent, client: APIClient) {
        switch event {
        case .inboxAdded(let item):
            guard !contains(messageId: item.message.id) else { return }
            items.insert(item, at: 0)
        case .inboxDeleted(let messageId):
            items.removeAll { $0.message.id == messageId }
        case .inboxCleared:
            items = []
        case .connected:
            // 切れていた間の分を取り直す
            Task { await load(client: client) }
        default:
            break
        }
    }
}

/// `/message/inbox` の1件（キーが大文字の "Message" なのに注意）
private struct InboxRow: Decodable {
    let type: String
    let happendAt: Date
    let message: Message

    enum CodingKeys: String, CodingKey {
        case type, happendAt
        case message = "Message"
    }

    var item: InboxItem {
        InboxItem(kind: InboxItem.Kind(rawValue: type) ?? .mention, message: message, happenedAt: happendAt)
    }
}

/// WebSocket の inbox::Added の data（`{ message, type }`。こちらは小文字の "message"）
struct InboxAddedPayload: Decodable {
    let type: String
    let message: Message

    var item: InboxItem {
        InboxItem(kind: InboxItem.Kind(rawValue: type) ?? .mention, message: message, happenedAt: message.createdAt)
    }
}
