import Foundation
import Observation

/// 絵文字1つ分のデータ
struct EmojiEntry: Identifiable, Hashable {
    /// 絵文字そのもの（"👍️"）
    let emoji: String
    /// サーバーに送る絵文字コード。Web 版（emoji-picker-element）と同じく shortcodes の1つ目（"+1"）
    let code: String
    let shortcodes: [String]
    /// emojibase のグループ番号（0: 顔, 1: 人, …, 9: 旗）
    let group: Int
    /// 検索用の名前とタグ（英語と日本語）
    let keywords: [String]
    /// 日本語名（"サムズアップ"）
    let nameJa: String?

    var id: String { code }
}

/// サーバーに登録されたカスタム絵文字
struct CustomEmoji: Decodable, Identifiable, Hashable {
    let code: String
    var id: String { code }
}

/// 絵文字データを持つストア。
/// Web 版の emoji-picker-element と同じ CDN のデータ（emojibase）を使うので、
/// 絵文字コード（shortcode）が Web 版と必ず一致する
@Observable
final class EmojiStore {
    private(set) var entries: [EmojiEntry] = []
    private(set) var customEmojis: [CustomEmoji] = []

    /// 絵文字コード → 絵文字（shortcodes のどれでも引けるようにする。Web 版の getEmojiByShortcode と同じ）
    @ObservationIgnored private var emojiByCode: [String: String] = [:]
    /// 絵文字（異体字セレクタ除去）→ 絵文字コード
    @ObservationIgnored private var codeByEmoji: [String: String] = [:]

    /// Web 版と同じデータの URL（emoji-picker-element の DEFAULT_DATA_SOURCE。^ は %5E）
    private static let englishURL = URL(string: "https://cdn.jsdelivr.net/npm/emoji-picker-element-data@%5E1/en/emojibase/data.json")!
    /// 日本語の名前・タグ（検索用。こちらには shortcodes は入っていない）
    private static let japaneseURL = URL(string: "https://cdn.jsdelivr.net/npm/emoji-picker-element-data@%5E1/ja/emojibase/data.json")!

    // MARK: - 取得

    /// 端末に保存したデータをすぐ使い、その後 CDN に更新が無いか確かめる
    func load() async {
        if let en = Self.cachedData(for: Self.englishURL) {
            apply(english: en, japanese: Self.cachedData(for: Self.japaneseURL))
        }
        let enChanged = await Self.refresh(Self.englishURL)
        let jaChanged = await Self.refresh(Self.japaneseURL)
        if enChanged || jaChanged || entries.isEmpty,
           let en = Self.cachedData(for: Self.englishURL) {
            apply(english: en, japanese: Self.cachedData(for: Self.japaneseURL))
        }
    }

    func loadCustomEmojis(client: APIClient) async {
        if let emojis: [CustomEmoji] = try? await client.get("server/custom-emoji") {
            customEmojis = emojis
        }
    }

    // MARK: - 引く

    /// 絵文字コード → 絵文字。無ければ nil（カスタム絵文字か、知らないコード）
    func emoji(for code: String) -> String? {
        emojiByCode[code]
    }

    /// 絵文字 → 絵文字コード
    func code(for emoji: String) -> String? {
        codeByEmoji[Self.normalize(emoji)]
    }

    func isCustom(_ code: String) -> Bool {
        customEmojis.contains { $0.code == code }
    }

    // MARK: - 中身

    private struct RawEmoji: Decodable {
        let emoji: String
        let shortcodes: [String]?
        let annotation: String?
        let tags: [String]?
        let group: Int?
    }

    private func apply(english: Data, japanese: Data?) {
        guard let en = try? JSONDecoder().decode([RawEmoji].self, from: english) else { return }
        let ja = japanese.flatMap { try? JSONDecoder().decode([RawEmoji].self, from: $0) } ?? []
        let jaByEmoji = Dictionary(ja.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [EmojiEntry] = []
        var emojiByCode: [String: String] = [:]
        var codeByEmoji: [String: String] = [:]
        for raw in en {
            guard let shortcodes = raw.shortcodes, let code = shortcodes.first else { continue }
            let jaRaw = jaByEmoji[raw.emoji]
            let keywords = shortcodes + [raw.annotation, jaRaw?.annotation].compactMap { $0 }
                + (raw.tags ?? []) + (jaRaw?.tags ?? [])
            entries.append(EmojiEntry(
                emoji: raw.emoji,
                code: code,
                shortcodes: shortcodes,
                group: raw.group ?? 0,
                keywords: keywords,
                nameJa: jaRaw?.annotation
            ))
            for shortcode in shortcodes where emojiByCode[shortcode] == nil {
                emojiByCode[shortcode] = raw.emoji
            }
            codeByEmoji[Self.normalize(raw.emoji)] = code
        }
        self.entries = entries
        self.emojiByCode = emojiByCode
        self.codeByEmoji = codeByEmoji
    }

    /// "👍️"（異体字セレクタ U+FE0F 付き）と "👍" を同じものとして扱う
    private static func normalize(_ emoji: String) -> String {
        String(emoji.unicodeScalars.filter { $0 != "\u{FE0F}" }.map(Character.init))
    }

    // MARK: - キャッシュ（emoji-picker-element が IndexedDB + ETag でしているのと同じ考え方）

    private static func cacheFile(for url: URL) -> URL {
        let name = url.pathComponents.dropFirst().joined(separator: "_")
        return URL.cachesDirectory.appending(path: "emoji-\(name)")
    }

    private static func cachedData(for url: URL) -> Data? {
        try? Data(contentsOf: cacheFile(for: url))
    }

    /// ETag で変わったかを確かめ、変わっていれば保存し直す。変わったら true
    private static func refresh(_ url: URL) async -> Bool {
        let etagKey = "emoji-etag-\(url.absoluteString)"
        var request = URLRequest(url: url)
        // URLSession 自身のキャッシュは使わず、ETag での確認を自分で行う
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if cachedData(for: url) != nil, let etag = UserDefaults.standard.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return false } // 304（変わっていない）や通信失敗なら保存済みのまま
        try? data.write(to: cacheFile(for: url))
        UserDefaults.standard.set(http.value(forHTTPHeaderField: "ETag"), forKey: etagKey)
        return true
    }
}
