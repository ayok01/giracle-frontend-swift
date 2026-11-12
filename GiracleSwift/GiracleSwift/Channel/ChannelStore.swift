import SwiftUI
import Observation

/// チャンネル一覧・参加状態・並び順を持つストア（チャンネル系の画面で共有する）
@Observable
final class ChannelStore {
    /// 自分が見られる全チャンネル（`/channel/list`）
    private(set) var allChannels: [Channel] = []
    /// 参加中のチャンネルId（`/user/info/:自分` の ChannelJoin）
    private(set) var joinedIds: Set<String> = []
    /// 未読メッセージがあるチャンネルId（`/message/get-new`）
    private(set) var unreadIds: Set<String> = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    /// 並び順。Web 版が localStorage に保存しているのと同じく、端末に保存する
    private var order: [String] = UserDefaults.standard.stringArray(forKey: "channelOrder") ?? [] {
        didSet { UserDefaults.standard.set(order, forKey: "channelOrder") }
    }

    /// 参加中のチャンネルを並び順どおりに。並び順に無いもの（新しく参加した等）は最後
    var joinedChannels: [Channel] {
        allChannels
            .filter { joinedIds.contains($0.id) }
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    func isJoined(_ channelId: String) -> Bool {
        joinedIds.contains(channelId)
    }

    func load(client: APIClient, myUserId: String) async {
        defer { hasLoaded = true }
        do {
            let channels: [Channel] = try await client.get("channel/list")
            let me: User = try await client.get("user/info/\(myUserId)")
            allChannels = channels
            joinedIds = Set(me.channelJoins?.map(\.channelId) ?? [])
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadUnread(client: client)
    }

    /// 参加中チャンネルの未読状態を取り直す
    func loadUnread(client: APIClient) async {
        // { "チャンネルId": 未読があるか } の形で返ってくる
        guard let news: [String: Bool] = try? await client.get("message/get-new") else { return }
        unreadIds = Set(news.filter(\.value).keys)
    }

    func isUnread(_ channelId: String) -> Bool {
        unreadIds.contains(channelId)
    }

    /// そのメッセージまで読んだことをサーバーに伝える（Web 版と同じくメッセージの createdAt を送る）
    func markAsRead(_ message: Message, client: APIClient) async {
        unreadIds.remove(message.channelId)
        // 既読時刻がすでにこれより新しいとサーバーは 400 を返すが、その場合は無視してよい
        try? await client.post(
            "message/read-time/update",
            body: ReadTimeUpdateRequest(channelId: message.channelId, readTime: message.createdAt)
        )
    }

    /// WebSocket のイベントで未読状態を更新する
    func apply(_ event: RealtimeEvent, myUserId: String?, client: APIClient) {
        switch event {
        case .messageSent(let message) where message.userId != myUserId && joinedIds.contains(message.channelId):
            // 開いているチャンネルなら、ChannelView がすぐ既読にするのでこの印は消える
            unreadIds.insert(message.channelId)
        case .readTimeUpdated(let channelId):
            unreadIds.remove(channelId)
        case .connected:
            // 切れていた間に届いた分を取り直す
            Task { await loadUnread(client: client) }
        default:
            break
        }
    }

    func join(_ channelId: String, client: APIClient) async throws {
        try await client.post("channel/join", body: ["channelId": channelId])
        joinedIds.insert(channelId)
    }

    func leave(_ channelId: String, client: APIClient) async throws {
        try await client.post("channel/leave", body: ["channelId": channelId])
        joinedIds.remove(channelId)
    }

    /// 一覧での並べ替えを反映して保存する
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = joinedChannels.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        order = ids
    }
}

private struct ReadTimeUpdateRequest: Encodable {
    let channelId: String
    let readTime: Date

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channelId, forKey: .channelId)
        // 標準の JSONEncoder は Date を数値にしてしまうので、ミリ秒付きの ISO 8601 文字列で送る。
        // Date は内部が小数なので ".002" が ".0019999…" になり、文字列にすると ".001" に切り捨てられる。
        // 既読時刻がメッセージより 1ms 古いと未読のまま残るので、0.5ms 足してから文字列にする
        try container.encode(
            readTime.addingTimeInterval(0.0005)
                .formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            forKey: .readTime
        )
    }

    enum CodingKeys: String, CodingKey {
        case channelId, readTime
    }
}
