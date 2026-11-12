import Foundation

/// 入力中のメンションを扱う。
/// 入力欄では読みやすい "@名前" で見せて、送るときにサーバーの形式 "@<ユーザーId>" に変える
struct MentionDraft {
    /// 候補から選んだユーザー（名前 → ユーザーId）
    private(set) var selected: [String: String] = [:]

    /// 文の最後で入力中の "@…" の … の部分。入力中でなければ nil。
    /// 例: "こんにちは @al" → "al"、"@" → ""、"メール a@b" → nil（直前が空白か文頭のときだけ）
    static func query(in text: String) -> String? {
        guard let match = text.firstMatch(of: #/(?:^|\s)@([^\s@<>]*)$/#) else { return nil }
        return String(match.output.1)
    }

    /// 入力中の "@…" を "@名前 " に置き換えて、選んだユーザーを覚える
    mutating func insert(_ user: User, into text: inout String) {
        guard let name = user.name, let query = Self.query(in: text) else { return }
        text.removeLast(query.count + 1) // "@" + 入力中の文字
        text += "@\(name) "
        selected[name] = user.id
    }

    /// 送る直前に "@名前" を "@<ユーザーId>" に変える。
    /// 長い名前から置き換える（"@Alex" と "@Alex.exe" があるとき短い方が先に当たらないように）
    func encode(_ text: String) -> String {
        var result = text
        for (name, id) in selected.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacing("@\(name)", with: "@<\(id)>")
        }
        return result
    }

    /// 編集するとき、"@<ユーザーId>" を "@名前" に戻して入力欄に入れる
    mutating func decode(_ content: String, users: [String: User]) -> String {
        var result = content
        for match in content.matches(of: #/@<([a-f0-9-]+)>/#) {
            let id = String(match.output.1)
            guard let name = users[id]?.name else { continue }
            result = result.replacing(String(match.output.0), with: "@\(name)")
            selected[name] = id
        }
        return result
    }

    mutating func reset() {
        selected = [:]
    }
}
