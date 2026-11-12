import Foundation
import Observation

/// `/ws` につなぎっぱなしにして、届いたイベントを画面に配る
@Observable
final class RealtimeClient {
    /// 画面ごとの受け取り口（addEventListener したリスナーの一覧のようなもの）
    @ObservationIgnored
    private var continuations: [UUID: AsyncStream<RealtimeEvent>.Continuation] = [:]

    /// イベントを受け取る。`for await event in realtime.events()` で使う
    func events() -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream<RealtimeEvent>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        // 画面が閉じて for await が終わったら登録を外す（removeEventListener 相当）
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
        return stream
    }

    /// 接続して受信し続ける。切れたら少し待ってつなぎ直す。
    /// 呼び出し元の Task がキャンセルされる（画面が消える）と終わる。
    func run(baseURL: URL) async {
        while !Task.isCancelled {
            await connectOnce(baseURL: baseURL)
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func connectOnce(baseURL: URL) async {
        guard let request = Self.makeRequest(baseURL: baseURL) else { return }
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()

        // 最初の ping が送れたら接続できたとみなす（失敗なら run() がつなぎ直す）
        do {
            try await socket.send(.string(Self.ping))
        } catch {
            return
        }
        broadcast(.connected)

        // サーバーに切断されないよう定期的に ping を送る
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                try? await socket.send(.string(Self.ping))
            }
        }
        defer { pinger.cancel() }

        await withTaskCancellationHandler {
            do {
                while true {
                    let message = try await socket.receive()
                    if case .string(let text) = message, let event = RealtimeEvent.decode(text) {
                        broadcast(event)
                    }
                }
            } catch {
                // 切断・エラー。run() がつなぎ直す
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static let ping = #"{"signal":"ping","data":"ping"}"#

    /// 登録されている全画面にイベントを配る
    private func broadcast(_ event: RealtimeEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    /// バックエンド (src/ws.ts) の接続条件に合わせたリクエストを作る
    /// - Cookie の token で認証する
    /// - Origin ヘッダーが必須
    private static func makeRequest(baseURL: URL) -> URLRequest? {
        // https://example.com/api → wss://example.com/api/ws
        guard var components = URLComponents(url: baseURL.appending(path: "ws"), resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host
        else { return nil }
        components.scheme = scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        let port = components.port.map { ":\($0)" } ?? ""
        request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")

        // サインイン時に保存された Cookie を明示的に載せる
        request.httpShouldHandleCookies = false
        let cookies = HTTPCookieStorage.shared.cookies(for: baseURL) ?? []
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}
