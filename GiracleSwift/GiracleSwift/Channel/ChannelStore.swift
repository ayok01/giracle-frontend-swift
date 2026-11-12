import SwiftUI
import Observation

/// チャンネル一覧・参加状態・並び順を持つストア（チャンネル系の画面で共有する）
@Observable
final class ChannelStore {
    /// 自分が見られる全チャンネル（`/channel/list`）
    private(set) var allChannels: [Channel] = []
    /// 参加中のチャンネルId（`/user/info/:自分` の ChannelJoin）
    private(set) var joinedIds: Set<String> = []
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
