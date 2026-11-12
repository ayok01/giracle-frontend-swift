import SwiftUI

/// メッセージの検索（Web 版の /search に相当）。タブバーの検索タブに置く
struct SearchView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(ChannelStore.self) private var channelStore

    // MARK: - 検索の条件

    @State private var query = ""
    /// 絞り込むチャンネル（nil ならすべての見られるチャンネル）
    @State private var channelId: String?
    @State private var newestFirst = true
    @State private var onlyWithFiles = false
    @State private var onlyWithLinks = false

    // MARK: - 結果

    @State private var results: [Message] = []
    /// 次に読み込むページ（1 から。30 件ずつ）
    @State private var nextPage = 1
    /// まだ続きがあるか（30 件未満しか返ってこなければ終わり）
    @State private var hasMore = false
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var users: [String: User] = [:]
    @State private var path: [ChannelRoute] = []

    private static let pageSize = 30

    /// 検索できる条件がそろっているか（本文が空でも、添付やリンクの絞り込みだけで探せる）
    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || onlyWithFiles || onlyWithLinks || channelId != nil
    }

    private var formatter: MessageFormatter {
        MessageFormatter(
            users: users,
            channels: Dictionary(uniqueKeysWithValues: channelStore.allChannels.map { ($0.id, $0) }),
            myUserId: auth.userId
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                filterSection

                // 案内やエラーは、一覧に重ねると絞り込みのカードの上にかぶるので、絞り込みの下に並べる
                statusSection

                ForEach(results) { message in
                    Button {
                        open(message)
                    } label: {
                        MessageSummaryRow(
                            message: message,
                            user: users[message.userId],
                            channelName: channelName(message.channelId),
                            text: formatter.format(message.content),
                            iconURL: auth.client?.baseURL.appending(path: "user/icon/\(message.userId)"),
                            showsDate: true
                        )
                    }
                    .buttonStyle(.plain)
                    // 最後の行が見えたら続きを読み込む（受信箱以外の一覧と同じ無限スクロール）
                    .task {
                        if message.id == results.last?.id {
                            await search(more: true)
                        }
                    }
                }

                if isSearching, !results.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("検索")
            // 検索タブでは置き場所を iOS に任せると最初は隠れるので、タイトルの下にいつも出す
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "メッセージを検索")
            // キーボードの「検索」で探す（Web 版も検索ボタンを押したときだけ探す）
            .onSubmit(of: .search) {
                Task { await search(more: false) }
            }
            // 絞り込みを変えたら、検索済みならその条件で探し直す
            .onChange(of: [channelId ?? "", "\(newestFirst)", "\(onlyWithFiles)", "\(onlyWithLinks)"]) {
                if hasSearched {
                    Task { await search(more: false) }
                }
            }
            .navigationDestination(for: ChannelRoute.self) { route in
                ChannelView(channel: route.channel, initialMessageId: route.messageId)
            }
        }
    }

    /// 絞り込みの条件（チャンネル・並び順・添付・リンク）
    private var filterSection: some View {
        Section {
            Picker("チャンネル", selection: $channelId) {
                Text("すべて").tag(String?.none)
                ForEach(channelStore.allChannels) { channel in
                    Text(channel.name).tag(Optional(channel.id))
                }
            }
            Picker("並び順", selection: $newestFirst) {
                Text("新しい順").tag(true)
                Text("古い順").tag(false)
            }
            Toggle("添付ファイルがあるもの", isOn: $onlyWithFiles)
            Toggle("リンクがあるもの", isOn: $onlyWithLinks)
        }
    }

    /// 結果がまだ無いときの案内（読み込み中・エラー・見つからない・未検索）
    @ViewBuilder
    private var statusSection: some View {
        if results.isEmpty {
            Section {
                Group {
                    if isSearching {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else if let errorMessage {
                        ContentUnavailableView("検索できませんでした", systemImage: "exclamationmark.magnifyingglass", description: Text(errorMessage))
                    } else if hasSearched {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ContentUnavailableView(
                            "メッセージを検索",
                            systemImage: "magnifyingglass",
                            description: Text("言葉を入れてキーボードの「検索」を押してください")
                        )
                    }
                }
                // 一覧の行の白い背景を付けず、画面の背景になじませる
                .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: - 検索

    /// 検索する。more が true なら続きのページを足す
    private func search(more: Bool) async {
        guard let client = auth.client, canSearch, !isSearching else { return }
        if more, !hasMore { return }
        let page = more ? nextPage : 1

        isSearching = true
        defer { isSearching = false }
        do {
            let found: [Message] = try await client.get("message/search", query: queryItems(page: page))
            results = more ? results + found : found
            nextPage = page + 1
            hasMore = found.count == Self.pageSize
            hasSearched = true
            errorMessage = nil
            await loadUsers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func queryItems(page: Int) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "loadIndex", value: String(page)),
            URLQueryItem(name: "sort", value: newestFirst ? "desc" : "asc"),
        ]
        let content = query.trimmingCharacters(in: .whitespaces)
        if !content.isEmpty {
            items.append(URLQueryItem(name: "content", value: content))
        }
        if let channelId {
            items.append(URLQueryItem(name: "channelId", value: channelId))
        }
        // オフのときは送らない（送ると「無いもの」に絞り込まれてしまう）
        if onlyWithFiles {
            items.append(URLQueryItem(name: "hasFileAttachment", value: "true"))
        }
        if onlyWithLinks {
            items.append(URLQueryItem(name: "hasUrlPreview", value: "true"))
        }
        return items
    }

    private func loadUsers() async {
        guard let client = auth.client else { return }
        let unknownIds = Set(results.flatMap(\.relatedUserIds)).subtracting(users.keys)
        for userId in unknownIds {
            if let user: User = try? await client.get("user/info/\(userId)") {
                users[userId] = user
            }
        }
    }

    /// タップでそのメッセージの位置を開く（受信箱と同じ「メッセージへ移動」）
    private func open(_ message: Message) {
        guard let channel = channelStore.allChannels.first(where: { $0.id == message.channelId }) else { return }
        path.append(ChannelRoute(channel: channel, messageId: message.id))
    }

    private func channelName(_ channelId: String) -> String {
        channelStore.allChannels.first { $0.id == channelId }?.name ?? "不明なチャンネル"
    }
}
