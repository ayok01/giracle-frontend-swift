import SwiftUI

/// チャンネルのメッセージ画面
struct ChannelView: View {
    let channel: Channel

    @Environment(AuthStore.self) private var auth
    @Environment(RealtimeClient.self) private var realtime
    @Environment(ChannelStore.self) private var channelStore

    /// 古い順（画面の上から下へ並べる順）
    @State private var messages: [Message] = []
    /// userId → User。名前を表示するために取ってきたユーザーを覚えておく
    @State private var users: [String: User] = [:]
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    /// いちばん古いメッセージまで読み込んだか
    @State private var atTop = false
    @State private var isLoadingOlder = false
    /// スクロール位置。送信後に最新メッセージまで戻すのに使う
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    /// ナビゲーションバー・入力欄・キーボードの分の余白（反転に合わせて自分で付ける）
    @State private var safeAreaInsets = EdgeInsets()

    @State private var draft = ""
    @State private var isSending = false
    @State private var sendError: String?

    private var formatter: MessageFormatter {
        MessageFormatter(
            users: users,
            channels: Dictionary(uniqueKeysWithValues: channelStore.allChannels.map { ($0.id, $0) }),
            myUserId: auth.userId
        )
    }

    var body: some View {
        // 一覧ごと上下反転したスクロール（チャットの定番。React Native の FlatList inverted と同じ）。
        // スクロールの「先頭」が画面の下になるので、
        // - 開いたとき何もしなくても最新（先頭）が見える
        // - 古いメッセージは「末尾」に足される = 見ている場所より後ろなので位置がずれない
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // 新しい順に並べる（先頭 = 画面の一番下）
                ForEach(messages.reversed()) { message in
                    Group {
                        if let system = message.systemContent {
                            SystemMessageRow(content: system, user: users[system.targetUserId])
                        } else {
                            MessageRow(
                                message: message,
                                text: formatter.format(message.content),
                                user: users[message.userId],
                                iconURL: iconURL(for: message.userId)
                            )
                        }
                    }
                    // 一覧ごと反転しているので、各行はもう一度反転して元の向きに戻す
                    .flippedUpsideDown()
                }

                // 末尾（= 画面の一番上）に来たら古いメッセージを読み込む見張り役。
                // id が変わる（古いのを読み込んだ）たびに、まだ見えていればもう一度実行される
                if hasLoaded, !atTop, !messages.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task(id: messages.first?.id) {
                            await loadOlder()
                        }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .flippedUpsideDown()
        .scrollPosition($scrollPosition)
        // 反転すると、ナビゲーションバーや入力欄・キーボードの分の余白も上下が入れ替わってしまう。
        // そこで自動の余白は無効にして、測った値を上下逆にして自分で付ける
        .contentMargins(.top, safeAreaInsets.bottom, for: .automatic)
        .contentMargins(.bottom, safeAreaInsets.top, for: .automatic)
        // 反転したスクロールでは、バーの後ろのぼかし（スクロールエッジ効果）が
        // 反転前の向きで計算されて画面全体にかかってしまう（iOS 26〜の既知の不具合 FB20540755）。
        // この画面では切って、代わりにナビゲーションバーに背景を付ける
        .scrollEdgeEffectHidden(true, for: .all)
        .ignoresSafeArea(edges: .vertical)
        .onGeometryChange(for: EdgeInsets.self) { geometry in
            geometry.safeAreaInsets
        } action: { insets in
            safeAreaInsets = insets
        }
        // 一覧を下にスワイプするとキーボードが閉じる
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        .toolbar {
            // ぼかしが無い分、チャンネル名をガラスのカプセルに乗せて読みやすくする
            // （navigationTitle は戻るボタンの長押しメニューなどで使われるので残す）
            ToolbarItem(placement: .principal) {
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    // ツールバーのボタン（戻るボタン）と同じ高さにそろえる
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        // チャンネル内ではタブバーを隠し、代わりに入力欄を置く
        .toolbarVisibility(.hidden, for: .tabBar)
        .task { await load() }
        // 画面を開いている間、WebSocket のイベントを受け取る
        .task {
            for await event in realtime.events() {
                apply(event)
            }
        }
        .overlay {
            if !hasLoaded {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableView(
                    "読み込めませんでした",
                    systemImage: "wifi.exclamationmark",
                    description: Text(errorMessage)
                )
            } else if messages.isEmpty {
                ContentUnavailableView("メッセージはまだありません", systemImage: "bubble")
            }
        }
        .alert(
            "送信できませんでした",
            isPresented: Binding(get: { sendError != nil }, set: { if !$0 { sendError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(sendError ?? "")
        }
    }

    /// 参加済みなら入力欄、未参加なら参加ボタン
    @ViewBuilder
    private var bottomBar: some View {
        if channelStore.isJoined(channel.id) {
            MessageInputBar(text: $draft, isSending: isSending) {
                Task { await send() }
            }
        } else if channelStore.hasLoaded {
            Button("このチャンネルに参加", systemImage: "plus") {
                Task { await join() }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.bottom, 8)
        }
    }

    private func load() async {
        guard let client = auth.client else { return }
        defer { hasLoaded = true }
        do {
            let result: MessageHistory = try await client.post(
                "channel/get-history/\(channel.id)",
                body: HistoryRequest(direction: .older)
            )
            messages = result.history.reversed()
            atTop = result.atTop
            errorMessage = nil
            await loadUsers(client: client)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// いちばん古いメッセージより前の30件を読み込む
    private func loadOlder() async {
        guard hasLoaded, !atTop, !isLoadingOlder,
              let client = auth.client, let oldest = messages.first
        else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let result: MessageHistory = try await client.post(
                "channel/get-history/\(channel.id)",
                body: HistoryRequest(direction: .older, messageIdFrom: oldest.id)
            )
            merge(result.history)
            atTop = result.atTop
            await loadUsers(client: client)
        } catch {
            // 失敗しても、見張り役がもう一度表示されたときにやり直す
        }
    }

    /// いちばん新しいメッセージより後を読み込む（WebSocket が切れていた間の分）
    private func loadNewer() async {
        guard let client = auth.client, let newest = messages.last else { return }
        do {
            let result: MessageHistory = try await client.post(
                "channel/get-history/\(channel.id)",
                body: HistoryRequest(direction: .newer, messageIdFrom: newest.id)
            )
            if result.atEnd {
                merge(result.history)
                await loadUsers(client: client)
            } else {
                // 30件より多く取りこぼしたので、最新から読み直す
                await load()
            }
        } catch {}
    }

    /// 取得したメッセージを今の一覧に混ぜる。
    /// 基準にしたメッセージ自身も返ってくるので、id で重複を除いてから古い順に並べ直す
    private func merge(_ incoming: [Message]) {
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in incoming {
            byId[message.id] = message
        }
        messages = byId.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// まだ知らないユーザーの情報をまとめて取ってくる
    private func loadUsers(client: APIClient) async {
        let unknownIds = Set(messages.flatMap(\.relatedUserIds)).subtracting(users.keys)
        for userId in unknownIds {
            if let user: User = try? await client.get("user/info/\(userId)") {
                users[userId] = user
            }
        }
    }

    private func send() async {
        guard let client = auth.client else { return }
        let text = draft
        draft = ""
        isSending = true
        defer { isSending = false }
        do {
            // サーバーが保存したメッセージを返すので、それを一覧の最後に足す
            let sent: Message = try await client.post(
                "message/send",
                body: SendRequest(channelId: channel.id, message: text)
            )
            // WebSocket の方が先に届いていることもあるので重複チェック
            if !messages.contains(where: { $0.id == sent.id }) {
                messages.append(sent)
            }
            // 過去を読んでいる途中でも、送ったら最新（反転しているのでスクロールの先頭）へ戻る
            withAnimation {
                scrollPosition.scrollTo(edge: .top)
            }
            await loadUsers(client: client)
        } catch {
            // 失敗したら書いた文章を戻す
            draft = text
            sendError = error.localizedDescription
        }
    }

    /// WebSocket で届いたイベントをこのチャンネルの一覧に反映する
    private func apply(_ event: RealtimeEvent) {
        switch event {
        case .messageSent(let message) where message.channelId == channel.id:
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            if let client = auth.client {
                Task { await loadUsers(client: client) }
            }
        case .messageUpdated(let message) where message.channelId == channel.id:
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            }
        case .messageDeleted(let messageId, let channelId) where channelId == channel.id:
            messages.removeAll { $0.id == messageId }
        case .connected:
            // つなぎ直したら、切れていた間のメッセージを取りに行く
            if hasLoaded {
                Task { await loadNewer() }
            }
        default:
            // 他のチャンネルのイベント
            break
        }
    }

    private func join() async {
        guard let client = auth.client else { return }
        do {
            try await channelStore.join(channel.id, client: client)
            // 「参加しました」のお知らせを表示するため読み直す
            await load()
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func iconURL(for userId: String) -> URL? {
        auth.client?.baseURL.appending(path: "user/icon/\(userId)")
    }
}

private struct HistoryRequest: Encodable {
    enum Direction: String, Encodable {
        case older, newer
    }

    var fetchLength = 30
    let fetchDirection: Direction
    /// 基準にするメッセージ。nil なら最新から（JSON には含めない）
    let messageIdFrom: String?

    init(direction: Direction, messageIdFrom: String? = nil) {
        self.fetchDirection = direction
        self.messageIdFrom = messageIdFrom
    }
}

private struct SendRequest: Encodable {
    let channelId: String
    let message: String
}

private struct MessageRow: View {
    let message: Message
    let text: AttributedString
    let user: User?
    let iconURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // URLSession.shared を使うので Cookie も自動で送られる
            AsyncImage(url: iconURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 36, height: 36)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(user?.name ?? "…")
                        .font(.subheadline.bold())
                    Text(message.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if message.isEdited {
                        Text("(編集済み)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(text)
                    .textSelection(.enabled)
            }
        }
    }
}

/// 参加・退出などのお知らせ
private struct SystemMessageRow: View {
    let content: SystemMessageContent
    let user: User?

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: .capsule)
            .frame(maxWidth: .infinity)
    }

    private var name: String { user?.name ?? "不明なユーザー" }

    private var text: String {
        switch content.messageTerm {
        case .welcome: "\(name)さんがGiracleに参加しました！ようこそ"
        case .channelJoin: "\(name)さんがチャンネルへ参加しました！"
        case .channelLeft: "\(name)さんがチャンネルを退出しました。"
        case .channelInvited: "\(name)さんが招待されました！"
        case .channelKicked: "\(name)さんがチャンネルからキックされました。"
        }
    }

    private var symbol: String {
        switch content.messageTerm {
        case .welcome: "hand.wave"
        case .channelJoin: "person.crop.circle.badge.plus"
        case .channelLeft: "rectangle.portrait.and.arrow.right"
        case .channelInvited: "envelope"
        case .channelKicked: "person.crop.circle.badge.xmark"
        }
    }
}
