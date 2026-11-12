import SwiftUI

/// 絵文字を選ぶ画面（Web 版の emoji-picker-element の Picker に相当）
struct EmojiPickerView: View {
    /// 選ばれた絵文字コードを受け取る
    let onSelect: (String) -> Void

    @Environment(EmojiStore.self) private var emojiStore
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    /// emojibase のグループ（2 は肌の色などの部品なので出さない）
    private static let groups: [(id: Int, name: String, symbol: String)] = [
        (0, "顔", "face.smiling"),
        (1, "人", "hand.wave"),
        (3, "動物・自然", "leaf"),
        (4, "食べ物", "fork.knife"),
        (5, "旅行・場所", "car"),
        (6, "アクティビティ", "soccerball"),
        (7, "もの", "lightbulb"),
        (8, "記号", "number"),
        (9, "旗", "flag"),
    ]

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4, pinnedViews: .sectionHeaders) {
                        if searchText.isEmpty {
                            allSections
                        } else {
                            ForEach(searchResults) { entry in
                                emojiButton(entry)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .safeAreaInset(edge: .bottom) {
                    if searchText.isEmpty {
                        groupTabs(proxy: proxy)
                    }
                }
            }
            .overlay {
                if emojiStore.entries.isEmpty {
                    ProgressView()
                } else if !searchText.isEmpty, searchResults.isEmpty, customResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("リアクション")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "絵文字を検索")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var allSections: some View {
        if !emojiStore.customEmojis.isEmpty {
            Section {
                ForEach(emojiStore.customEmojis) { custom in
                    pickButton(code: custom.code)
                }
            } header: {
                sectionHeader("カスタム")
            }
            .id("custom")
        }
        ForEach(Self.groups, id: \.id) { group in
            Section {
                ForEach(emojiStore.entries.filter { $0.group == group.id }) { entry in
                    emojiButton(entry)
                }
            } header: {
                sectionHeader(group.name)
            }
            .id(group.id)
        }
    }

    /// 下に並べるグループのタブ。押すとそのグループまでスクロール
    private func groupTabs(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if !emojiStore.customEmojis.isEmpty {
                    tabButton(symbol: "star", label: "カスタム") { proxy.scrollTo("custom", anchor: .top) }
                }
                ForEach(Self.groups, id: \.id) { group in
                    tabButton(symbol: group.symbol, label: group.name) { proxy.scrollTo(group.id, anchor: .top) }
                }
            }
            .padding(6)
        }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func tabButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 36)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .background(.background)
    }

    private func emojiButton(_ entry: EmojiEntry) -> some View {
        Button {
            select(entry.code)
        } label: {
            Text(entry.emoji)
                .font(.system(size: 30))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.nameJa ?? entry.code)
    }

    private func pickButton(code: String) -> some View {
        Button {
            select(code)
        } label: {
            EmojiView(code: code, size: 28)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private func select(_ code: String) {
        onSelect(code)
        dismiss()
    }

    // MARK: - 検索（ショートコード・英語名・日本語名・タグのどれかに含まれれば）

    private var searchResults: [EmojiEntry] {
        let query = searchText.lowercased()
        return emojiStore.entries.filter { entry in
            entry.keywords.contains { $0.lowercased().contains(query) }
        }
    }

    private var customResults: [CustomEmoji] {
        emojiStore.customEmojis.filter { $0.code.localizedCaseInsensitiveContains(searchText) }
    }
}
