import Foundation

/// `/server/config` が返すサーバーの設定（今使う項目だけ）。ログイン前でも取れる
struct ServerConfig: Decodable, Hashable {
    let name: String
    let introduction: String
}
