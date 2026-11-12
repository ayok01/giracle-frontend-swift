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
    /// スクロール位置。コードから特定のメッセージへスクロールさせるのに使う
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var scrollPhase: ScrollPhase = .idle

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // まだ古いメッセージがあることを示す
                if hasLoaded, !atTop, !messages.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }

                ForEach(messages) { message in
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
            }
            // 各メッセージを「スクロール先」として登録する（scrollPosition で id 指定するのに必要）
            .scrollTargetLayout()
            .padding()
        }
        .scrollPosition($scrollPosition)
        // 指で触っている・慣性で動いている、などのスクロール状態を覚えておく
        .onScrollPhaseChange { _, newPhase in
            scrollPhase = newPhase
        }
        // 上端から 200pt 以内に「入った瞬間」だけ古いメッセージを読み込む。
        // 値が false → true に変わったときだけ呼ばれるので、読み込みが繰り返されない。
        // さらに「ユーザーがスクロールしている最中」に限ることで、
        // 開いた直後（まだ一番下へ移動する前の一瞬）に反応してしまうのを防ぐ
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 200
        } action: { _, isNearTop in
            if isNearTop, scrollPhase == .interacting || scrollPhase == .decelerating {
                Task { await loadOlder() }
            }
        }
        // 新しいメッセージが増えたら一番下までスクロール（scrollIntoView 相当）
        .onChange(of: messages.last?.id) { oldLastId, lastId in
            // 最初の読み込み（空 → メッセージあり）は defaultScrollAnchor に任せる
            guard oldLastId != nil, let lastId else { return }
            withAnimation {
                scrollPosition.scrollTo(id: lastId, anchor: .bottom)
            }
        }
        // 開いたとき一番下（最新）から表示する。
        // .sizeChanges も下にしておくと、メッセージが入って中身の高さが確定していく間も
        // 下端に合わせ続けてくれる（キーボード表示で画面の高さが変わったときも同じ）
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // 一覧を下にスワイプするとキーボードが閉じる
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
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
            // 上に足した分だけ見ていた位置が下にずれるので、
            // 読み込む前に一番上にあったメッセージへ戻す（アニメーションなしで一瞬で）
            scrollPosition.scrollTo(id: oldest.id, anchor: .top)
            await loadUsers(client: client)
        } catch {
            // 失敗しても、もう一度上端に近づいたときにやり直す
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
