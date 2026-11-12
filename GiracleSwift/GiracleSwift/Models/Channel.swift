import Foundation

/// `/channel/list` などが返すチャンネル
struct Channel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let isArchived: Bool
    let createdUserId: String?
}
