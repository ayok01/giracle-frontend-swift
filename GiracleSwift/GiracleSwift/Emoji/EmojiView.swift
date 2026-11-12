import SwiftUI

/// 絵文字コードを表示する（Web 版の RenderEmoji と同じ考え方）
/// - 普通の絵文字 → 文字で
/// - カスタム絵文字 → サーバーの画像で
/// - どちらでもない（データ未取得など）→ コードの先頭を文字で
struct EmojiView: View {
    let code: String
    var size: CGFloat = 18

    @Environment(EmojiStore.self) private var emojiStore
    @Environment(AuthStore.self) private var auth

    var body: some View {
        if let emoji = emojiStore.emoji(for: code) {
            Text(emoji)
                .font(.system(size: size))
        } else if emojiStore.isCustom(code) {
            AsyncImage(url: auth.client?.baseURL.appending(path: "server/custom-emoji/\(code)")) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: size * 1.3, height: size * 1.3)
        } else {
            Text(code.prefix(5))
                .font(.system(size: size * 0.7))
                .foregroundStyle(.secondary)
        }
    }
}
