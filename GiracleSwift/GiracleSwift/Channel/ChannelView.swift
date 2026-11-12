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
    /// 画像ファイルId → 縦横サイズ（履歴を読み込むたびに足していく）
    @State private var imageDimensions: [String: ImageDimension] = [:]
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
    @FocusState private var isInputFocused: Bool

    /// 返信しようとしているメッセージ
    @State private var replyTarget: Message?
    /// 編集しているメッセージ
    @State private var editingMessage: Message?
    /// 削除の確認を出しているメッセージ
    @State private var deleteTarget: Message?
    /// 長押しされて操作のシートを出しているメッセージ
    @State private var actionTarget: Message?
    /// シートが閉じきってから実行する操作（キーボードを出す・確認を出すなどはシートが閉じてからでないと効かない）
    @State private var pendingAction: (() -> Void)?
    /// 返信先が一覧に読み込まれていないとき用に、個別に取ってきたメッセージ
    @State private var replyCache: [String: Message] = [:]

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
                            messageRow(message)
                                // 長押しで操作のシートを出す。
                                // 標準の contextMenu は反転した一覧だと浮かび上がる瞬間に裏返るため使わない
                                .onLongPressGesture {
                                    actionTarget = message
                                }
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
        // 長押しで出る操作のシート
        .sheet(item: $actionTarget, onDismiss: {
            pendingAction?()
            pendingAction = nil
        }) { message in
            List {
                Section {
                    messageRow(message)
                        .allowsHitTesting(false)
                }
                Section {
                    messageMenu(for: message)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // 長押しが決まったら「ブルッ」と振動させる
        .sensoryFeedback(.impact, trigger: actionTarget?.id) { _, newValue in
            newValue != nil
        }
        // 削除の確認。confirmationDialog は付けた画面の位置から吹き出しで出るため、
        // 反転したスクロールだと位置がずれる。常に画面中央に出る alert を使う
        .alert(
            "メッセージを削除しますか？",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { message in
            Button("削除", role: .destructive) {
                Task { await delete(message) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("この操作は取り消せません")
        }
    }

    private func messageRow(_ message: Message) -> some View {
        MessageRow(
            message: message,
            text: formatter.format(message.content),
            user: users[message.userId],
            iconURL: iconURL(for: message.userId),
            reply: replyPreview(for: message),
            imageDimensions: imageDimensions,
            baseURL: auth.client?.baseURL
        )
    }

    /// 操作のシートのボタン
    @ViewBuilder
    private func messageMenu(for message: Message) -> some View {
        let isJoined = channelStore.isJoined(channel.id)
        let isMine = message.userId == auth.userId

        if isJoined {
            Button("返信", systemImage: "arrowshape.turn.up.left") {
                closeSheet {
                    editingMessage = nil
                    replyTarget = message
                    isInputFocused = true
                }
            }
        }
        Button("コピー", systemImage: "doc.on.doc") {
            // @<userId> などは名前に置き換えた、見たままの文字をコピーする
            UIPasteboard.general.string = plainText(of: message)
            closeSheet {}
        }
        if isJoined, isMine {
            Button("編集", systemImage: "pencil") {
                closeSheet {
                    replyTarget = nil
                    editingMessage = message
                    draft = message.content
                    isInputFocused = true
                }
            }
        }
        if isMine {
            Button("削除", systemImage: "trash", role: .destructive) {
                closeSheet {
                    deleteTarget = message
                }
            }
        }
    }

    /// シートを閉じ、閉じきってから action を実行する
    private func closeSheet(then action: @escaping () -> Void) {
        pendingAction = action
        actionTarget = nil
    }

    /// 入力欄の上に出す「返信中」「編集中」
    private var inputBanner: InputBanner? {
        if let editingMessage {
            return InputBanner(systemImage: "pencil", title: "メッセージを編集", excerpt: plainText(of: editingMessage))
        }
        if let replyTarget {
            let name = users[replyTarget.userId]?.name ?? "…"
            return InputBanner(
                systemImage: "arrowshape.turn.up.left",
                title: "\(name) さんに返信",
                excerpt: plainText(of: replyTarget)
            )
        }
        return nil
    }

    /// 参加済みなら入力欄、未参加なら参加ボタン
    @ViewBuilder
    private var bottomBar: some View {
        if channelStore.isJoined(channel.id) {
            MessageInputBar(
                text: $draft,
                isSending: isSending,
                banner: inputBanner,
                focus: $isInputFocused,
                onCancelBanner: cancelReplyOrEdit
            ) {
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
            imageDimensions.merge(result.imageDimensions ?? [:]) { _, new in new }
            atTop = result.atTop
            errorMessage = nil
            await markLatestAsRead()
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
            imageDimensions.merge(result.imageDimensions ?? [:]) { _, new in new }
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
                imageDimensions.merge(result.imageDimensions ?? [:]) { _, new in new }
                await loadUsers(client: client)
            } else {
                // 30件より多く取りこぼしたので、最新から読み直す
                await load()
            }
        } catch {}
    }

    /// いちばん新しいメッセージまで読んだことにする（参加中のチャンネルだけ）
    private func markLatestAsRead() async {
        guard let client = auth.client, let newest = messages.last,
              channelStore.isJoined(channel.id)
        else { return }
        await channelStore.markAsRead(newest, client: client)
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

    /// 返信先と、まだ知らないユーザーの情報をまとめて取ってくる
    private func loadUsers(client: APIClient) async {
        await loadReplies(client: client)
        let allMessages = messages + Array(replyCache.values)
        let unknownIds = Set(allMessages.flatMap(\.relatedUserIds)).subtracting(users.keys)
        for userId in unknownIds {
            if let user: User = try? await client.get("user/info/\(userId)") {
                users[userId] = user
            }
        }
    }

    private func send() async {
        guard let client = auth.client else { return }
        if let editingMessage {
            await edit(editingMessage, client: client)
            return
        }
        let text = draft
        let replyTarget = replyTarget
        draft = ""
        self.replyTarget = nil
        isSending = true
        defer { isSending = false }
        do {
            // サーバーが保存したメッセージを返すので、それを一覧の最後に足す
            let sent: Message = try await client.post(
                "message/send",
                body: SendRequest(channelId: channel.id, message: text, replyingMessageId: replyTarget?.id)
            )
            // WebSocket の方が先に届いていることもあるので重複チェック
            if !messages.contains(where: { $0.id == sent.id }) {
                messages.append(sent)
            }
            // 過去を読んでいる途中でも、送ったら最新（反転しているのでスクロールの先頭）へ戻る
            withAnimation {
                scrollPosition.scrollTo(edge: .top)
            }
            // 自分のメッセージも「最新」として数えられるので、既読を進めておく
            await markLatestAsRead()
            await loadUsers(client: client)
        } catch {
            // 失敗したら書いた文章と返信先を戻す
            draft = text
            self.replyTarget = replyTarget
            sendError = error.localizedDescription
        }
    }

    private func edit(_ message: Message, client: APIClient) async {
        let text = draft
        isSending = true
        defer { isSending = false }
        do {
            let edit: MessageEdit = try await client.post(
                "message/edit",
                body: EditRequest(messageId: message.id, message: text)
            )
            // WebSocket でも届くが、返ってきた結果ですぐ反映する
            applyEdit(edit)
            editingMessage = nil
            draft = ""
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func delete(_ message: Message) async {
        guard let client = auth.client else { return }
        do {
            try await client.delete("message/delete", body: ["messageId": message.id])
            // WebSocket でも消えるが、すぐ反映させる
            messages.removeAll { $0.id == message.id }
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// 編集の結果を一覧（と返信先のキャッシュ）に反映する
    private func applyEdit(_ edit: MessageEdit) {
        if let index = messages.firstIndex(where: { $0.id == edit.id }) {
            messages[index].apply(edit)
        }
        replyCache[edit.id]?.apply(edit)
    }

    private func cancelReplyOrEdit() {
        if editingMessage != nil {
            draft = ""
        }
        editingMessage = nil
        replyTarget = nil
    }

    /// 返信先の表示に使う「返信先メッセージとその送信者」
    private func replyPreview(for message: Message) -> ReplyPreview? {
        guard let replyId = message.replyingMessageId else { return nil }
        let target = messages.first { $0.id == replyId } ?? replyCache[replyId]
        return ReplyPreview(
            name: target.flatMap { users[$0.userId]?.name },
            excerpt: target.map { plainText(of: $0) } ?? "読み込み中…"
        )
    }

    /// 返信先が一覧に無ければ個別に取ってくる（古すぎて読み込んでいない場合など）
    private func loadReplies(client: APIClient) async {
        let loadedIds = Set(messages.map(\.id)).union(replyCache.keys)
        let missingIds = Set(messages.compactMap(\.replyingMessageId)).subtracting(loadedIds)
        for id in missingIds {
            if let message: Message = try? await client.get("message/\(id)") {
                replyCache[id] = message
            }
        }
    }

    /// メンションなどを名前に置き換えた、見たままの文字
    private func plainText(of message: Message) -> String {
        let text = String(formatter.format(message.content).characters)
        if text.isEmpty, let file = message.files?.first {
            return file.isImage ? "画像" : file.actualFileName
        }
        return text
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
            // 開いている間に届いたものはその場で読んだことにする
            Task { await markLatestAsRead() }
        case .messageUpdated(let message) where message.channelId == channel.id:
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            }
        case .messageEdited(let edit) where edit.channelId == channel.id:
            applyEdit(edit)
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
    /// 返信先。nil なら JSON に含めない
    let replyingMessageId: String?
}

private struct EditRequest: Encodable {
    let messageId: String
    let message: String
}

/// 返信先の表示内容
private struct ReplyPreview {
    let name: String?
    let excerpt: String
}

private struct MessageRow: View {
    let message: Message
    let text: AttributedString
    let user: User?
    let iconURL: URL?
    let reply: ReplyPreview?
    let imageDimensions: [String: ImageDimension]
    let baseURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply {
                ReplyQuote(reply: reply)
                    // アイコンの右側（本文の位置）にそろえる
                    .padding(.leading, 46)
            }
            content
        }
        // 文字の無い余白部分を長押ししても反応するよう、行全体を触れる範囲にする
        .contentShape(.rect)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            // URLSession.shared を使うので Cookie も自動で送られる
            AsyncImage(url: iconURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 36, height: 36)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 6) {
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
                // 画像だけのメッセージは本文が空
                // 文字選択（textSelection）は長押しを奪ってしまうので付けない。コピーは長押しのシートから
                if !message.content.isEmpty {
                    Text(text)
                }
                MessageAttachments(message: message, imageDimensions: imageDimensions, baseURL: baseURL)
            }
        }
    }
}

/// 返信先の引用（1行）
private struct ReplyQuote: View {
    let reply: ReplyPreview

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption2)
            if let name = reply.name {
                Text(name)
                    .font(.caption.bold())
            }
            Text(reply.excerpt)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            // 左に縦線を引いて引用っぽく
            Capsule()
                .fill(.tertiary)
                .frame(width: 3)
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
