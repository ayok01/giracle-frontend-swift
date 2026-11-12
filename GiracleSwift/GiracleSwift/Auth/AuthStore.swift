import Foundation
import Observation

/// ログイン状態を持つアプリ全体のストア（React の Context + useState に近い）
@Observable
final class AuthStore {
    enum State {
        case checking
        case signedOut
        case signedIn(userId: String)
    }

    var state: State = .checking

    /// サインイン中の自分の userId
    var userId: String? {
        if case .signedIn(let userId) = state { userId } else { nil }
    }

    /// ユーザーが入力するドメイン（例: example.com）
    var serverHost: String = UserDefaults.standard.string(forKey: "serverHost") ?? "" {
        didSet { UserDefaults.standard.set(serverHost, forKey: "serverHost") }
    }

    var client: APIClient? {
        apiBaseURL(from: serverHost).map(APIClient.init)
    }

    /// 接続先サーバーの名前・紹介文（取れなければ nil）
    private(set) var serverConfig: ServerConfig?

    /// サーバーの設定を取り直す。ドメインが正しくなければ nil になる
    func loadServerConfig() async {
        guard let client else {
            serverConfig = nil
            return
        }
        serverConfig = try? await client.get("server/config")
    }

    /// 起動時に保存済み Cookie が有効か確認する
    func restore() async {
        await loadServerConfig()
        guard let client else {
            state = .signedOut
            return
        }
        do {
            let res: UserIdData = try await client.get("user/verify-token")
            state = .signedIn(userId: res.userId)
        } catch {
            state = .signedOut
        }
    }

    func signIn(username: String, password: String) async throws {
        guard let client else { throw APIError.invalidURL }
        let res: UserIdData = try await client.post(
            "user/sign-in",
            body: SignInBody(username: username, password: password)
        )
        state = .signedIn(userId: res.userId)
    }

    func signOut() async {
        // 失敗してもローカルではサインアウト扱いにする
        try? await client?.post("user/sign-out", body: [String: String]())
        state = .signedOut
    }
}

/// "example.com" → https://example.com/api
private func apiBaseURL(from host: String) -> URL? {
    let host = host.trimmingCharacters(in: .whitespaces)
    guard !host.isEmpty else { return nil }
    return URL(string: "https://\(host)/api")
}

private struct SignInBody: Encodable {
    let username: String
    let password: String
}

private struct UserIdData: Decodable {
    let userId: String
}
