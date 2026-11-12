import Foundation
import Observation

/// 誰がオンラインかを持つストア（アプリ全体で共有する）
@Observable
final class PresenceStore {
    private(set) var onlineIds: Set<String> = []

    func isOnline(_ userId: String) -> Bool {
        onlineIds.contains(userId)
    }

    func load(client: APIClient, myUserId: String?) async {
        guard let ids: [String] = try? await client.get("user/get-online") else { return }
        onlineIds = Set(ids)
        // 自分の接続通知は自分には届かない（サーバーの ws.publish は本人を除く）ので、自分で足す
        if let myUserId {
            onlineIds.insert(myUserId)
        }
    }

    /// WebSocket の user::Connected / user::Disconnected を反映する
    func apply(_ event: RealtimeEvent, client: APIClient, myUserId: String?) {
        switch event {
        case .userConnected(let userId):
            onlineIds.insert(userId)
        case .userDisconnected(let userId):
            // 他の端末が切れても、この端末がつながっている間は自分はオンライン
            guard userId != myUserId else { return }
            onlineIds.remove(userId)
        case .connected:
            // 切れていた間の出入りを取り直す
            Task { await load(client: client, myUserId: myUserId) }
        default:
            break
        }
    }
}
