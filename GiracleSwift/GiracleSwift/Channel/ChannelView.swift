import SwiftUI
import PhotosUI

/// チャンネルのメッセージ画面
struct ChannelView: View {
    let channel: Channel
    /// 開いたときに表示したいメッセージ（受信箱から開いたときなど）。nil なら最新
    var initialMessageId: String?

    @Environment(AuthStore.self) private var auth
    @Environment(RealtimeClient.self) private var realtime
    @Environment(ChannelStore.self) private var channelStore
    @Environment(EmojiStore.self) private var emojiStore
    @Environment(InboxStore.self) private var inbox

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
    /// 最新のメッセージまで表示しているか。指定したメッセージへ移動したときは false（それより新しいものは読み込んでいない）
    @State private var atEnd = true
    /// 過去を表示している間に、新しいメッセージが届いたか
    @State private var hasNewMessages = false
    /// 移動先として目立たせているメッセージ
    @State private var highlightedId: String?
    /// メッセージリンク先のメッセージ（メッセージId → メッセージ）
    @State private var linkedMessages: [String: Message] = [:]
    /// 取れなかったメッセージリンク先（削除済み・権限なし）
    @State private var unavailableLinks: Set<String> = []
    /// 別のチャンネルのメッセージリンクを開くときの行き先
    @State private var linkedRoute: ChannelRoute?
    @State private var isLoadingNewer = false
    /// スクロールの位置合わせ用の入れ物（クラスなので中身を変えても画面は描き直されない）
    @State private var scrollTracker = ScrollTracker()
    /// スクロール位置。送信後に最新メッセージまで戻すのに使う
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    /// ナビゲーションバー・入力欄・キーボードの分の余白（反転に合わせて自分で付ける）
    @State private var safeAreaInsets = EdgeInsets()

    @State private var draft = ""
    /// 送信前の添付画像
    @State private var attachments: [PendingAttachment] = []
    /// 入力中のメンション（"@名前" ⇄ "@<ユーザーId>" の変換）
    @State private var mentionDraft = MentionDraft()
    /// "@" 入力中に出す候補
    @State private var mentionCandidates: [User] = []
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
    /// 絵文字ピッカーを開いているメッセージ
    @State private var pickerTarget: Message?
    /// プロフィールを開いているユーザー
    @State private var profileTarget: ProfileTarget?
    @State private var isMembersPresented = false

    /// 長押しのシートに並べる、よく使う絵文字。
    /// コードは直接書かず、絵文字から引く（データ側でショートコードが変わっても追従できる）
    private static let quickReactionEmojis = ["👍", "❤️", "😂", "🎉", "👀", "🙏"]
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
                // 過去を表示中、先頭（= 画面の一番下）に来たら、それより新しいメッセージを読み込む見張り役
                if hasLoaded, !atEnd, !messages.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task(id: messages.last?.id) {
                            await loadNewerPage()
                        }
                }

                // 新しい順に並べる（先頭 = 画面の一番下）
                ForEach(messages.reversed()) { message in
                    Group {
                        if let system = message.systemContent {
                            SystemMessageRow(content: system, user: users[system.targetUserId])
                        } else {
                            messageRow(message)
                                // 移動先のメッセージは少しの間だけ色を付ける
                                .padding(highlightedId == message.id ? 6 : 0)
                                .background(
                                    highlightedId == message.id ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                                    in: .rect(cornerRadius: 12)
                                )
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
        // 中身の高さと見えている位置を覚えておく（新しいメッセージを先頭に足したときの位置合わせ用）。
        // スクロールのたびに変わる値なので @State には入れず、画面を描き直さない入れ物に入れる
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(contentHeight: geometry.contentSize.height, visibleTop: geometry.visibleRect.minY)
        } action: { _, metrics in
            scrollTracker.metrics = metrics
            // 先頭に足して中身が伸びたら、伸びた分だけずらして、見ていたメッセージを同じ場所に保つ
            if let before = scrollTracker.pendingAdjust, metrics.contentHeight != before.contentHeight {
                scrollTracker.pendingAdjust = nil
                scrollPosition.scrollTo(y: before.visibleTop + (metrics.contentHeight - before.contentHeight))
            }
        }
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
            // 右上：メンバー一覧
            ToolbarItem(placement: .topBarTrailing) {
                Button("メンバー", systemImage: "person.2") {
                    isMembersPresented = true
                }
            }
        }
        .sheet(isPresented: $isMembersPresented) {
            ChannelMembersView(channel: channel)
                .presentationDetents([.medium, .large])
        }
        // チャンネル内ではタブバーを隠し、代わりに入力欄を置く
        .toolbarVisibility(.hidden, for: .tabBar)
        .task {
            if let initialMessageId {
                await jump(to: initialMessageId)
            } else {
                await load()
            }
        }
        // "@…" を打っている間、チャンネルの参加者から候補を探す（0.2 秒の debounce。Web 版と同じ）
        .task(id: MentionDraft.query(in: draft)) {
            await searchMentionCandidates()
        }
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
                if channelStore.isJoined(channel.id) {
                    Section {
                        quickReactions(for: message)
                    }
                }
                Section {
                    messageMenu(for: message)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // ユーザーのプロフィール
        .sheet(item: $profileTarget) { target in
            ProfileView(userId: target.id)
                .presentationDetents([.medium, .large])
        }
        // 本文中のメンション（giracle-user:ユーザーId のリンク）をタップしたらプロフィールを開く。
        // それ以外の URL は通常どおりブラウザで開く
        .environment(\.openURL, OpenURLAction { url in
            if let userId = MessageFormatter.userId(fromProfileURL: url) {
                profileTarget = ProfileTarget(id: userId)
                return .handled
            }
            // 本文中の「#チャンネル名 のメッセージ」をタップしたらそのメッセージへ
            if let ref = MessageLinkRef(url: url) {
                openLink(ref)
                return .handled
            }
            return .systemAction
        })
        // 別のチャンネルのメッセージリンクを開いたら、そのチャンネルを積んで移動する
        .navigationDestination(item: $linkedRoute) { route in
            ChannelView(channel: route.channel, initialMessageId: route.messageId)
        }
        // すべての絵文字から選ぶピッカー
        .sheet(item: $pickerTarget) { message in
            EmojiPickerView { code in
                Task { await toggleReaction(code, on: message) }
            }
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
            baseURL: auth.client?.baseURL,
            onToggleReaction: { code in
                Task { await toggleReaction(code, on: message) }
            },
            onTapUser: { profileTarget = ProfileTarget(id: message.userId) },
            onTapReply: {
                if let replyId = message.replyingMessageId {
                    Task { await jump(to: replyId) }
                }
            },
            linkPreviews: message.messageLinks.map(linkPreview(for:)),
            onOpenLink: openLink
        )
    }

    /// 長押しのシートの、よく使う絵文字の列と「その他」ボタン
    private func quickReactions(for message: Message) -> some View {
        HStack {
            ForEach(Self.quickReactionEmojis, id: \.self) { emoji in
                if let code = emojiStore.code(for: emoji) {
                    Button {
                        closeSheet {
                            Task { await toggleReaction(code, on: message) }
                        }
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("その他", systemImage: "face.smiling") {
                closeSheet { pickerTarget = message }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    /// 自分が付けていれば外し、付けていなければ付ける（Web 版と同じ動き）
    private func toggleReaction(_ code: String, on message: Message) async {
        guard let client = auth.client else { return }
        // 最新の状態で判定する（シートを開いている間に変わっているかもしれない）
        let current = messages.first { $0.id == message.id } ?? message
        let body = ReactionRequest(messageId: message.id, channelId: message.channelId, emojiCode: code)
        do {
            if current.reactionSummary?.contains(where: { $0.emojiCode == code && $0.includingYou }) == true {
                let reaction: Reaction = try await client.delete("message/delete-emoji-reaction", body: body)
                updateMessage(message.id) { $0.removeReaction(reaction, myUserId: auth.userId) }
            } else {
                guard current.myReactionCount < 10 else {
                    sendError = "同一ユーザーによるリアクションは10個までです。"
                    return
                }
                let reaction: Reaction = try await client.post("message/emoji-reaction", body: body)
                updateMessage(message.id) { $0.addReaction(reaction, myUserId: auth.userId) }
            }
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// 一覧の中の1件を書き換える
    private func updateMessage(_ id: String, _ change: (inout Message) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            change(&messages[index])
        }
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
        Button("リンクをコピー", systemImage: "link") {
            // Web 版（HoverMenu.tsx）と同じ形式。貼り付けて送ると「#チャンネル名 のメッセージ」になる
            UIPasteboard.general.string = "&<\(message.channelId):\(message.id)>"
            closeSheet {}
        }
        if isJoined, isMine {
            Button("編集", systemImage: "pencil") {
                closeSheet {
                    replyTarget = nil
                    editingMessage = message
                    // "@<ユーザーId>" は "@名前" に戻して入力欄に入れる
                    mentionDraft.reset()
                    draft = mentionDraft.decode(message.content, users: users)
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

    /// 入力欄（か参加ボタン）と、過去を表示中なら「最新のメッセージへ」ボタン
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !atEnd {
                Button(
                    hasNewMessages ? "新しいメッセージがあります" : "最新のメッセージへ",
                    systemImage: "arrow.down"
                ) {
                    Task { await load() }
                }
                .buttonStyle(.glass)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputArea
        }
        .animation(.snappy, value: atEnd)
    }

    /// 参加済みなら入力欄、未参加なら参加ボタン
    @ViewBuilder
    private var inputArea: some View {
        if channelStore.isJoined(channel.id) {
            MessageInputBar(
                text: $draft,
                isSending: isSending,
                banner: inputBanner,
                focus: $isInputFocused,
                onCancelBanner: cancelReplyOrEdit,
                attachments: attachments,
                // 編集中は画像を足せない（編集 API は本文しか変えられない）
                onPickPhotos: editingMessage == nil ? { items in
                    Task { await addAttachments(from: items) }
                } : nil,
                onRemoveAttachment: { attachment in
                    attachments.removeAll { $0.id == attachment.id }
                },
                mentionCandidates: mentionCandidates,
                iconURL: iconURL(for:),
                onSelectMention: { user in
                    mentionDraft.insert(user, into: &draft)
                    mentionCandidates = []
                }
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
            atEnd = true
            hasNewMessages = false
            errorMessage = nil
            await markLatestAsRead()
            await loadUsers(client: client)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 指定したメッセージへ移動する。
    /// そのメッセージを「いちばん新しい位置」として、それ以前の30件を読み込む。
    /// 反転した一覧ではいちばん新しい位置が最初から画面の下に見えるので、スクロールさせずに表示できる
    /// （iOS 27 の LazyVStack では、まだ描画していない行への scrollTo が当てにならないため）
    private func jump(to messageId: String) async {
        guard let client = auth.client else { return }
        defer { hasLoaded = true }
        do {
            let result: MessageHistory = try await client.post(
                "channel/get-history/\(channel.id)",
                body: HistoryRequest(direction: .older, messageIdFrom: messageId)
            )
            messages = result.history.reversed()
            imageDimensions.merge(result.imageDimensions ?? [:]) { _, new in new }
            atTop = result.atTop
            // 指定したメッセージがチャンネルの最新ならそのまま最新表示と同じ
            atEnd = result.atEnd
            hasNewMessages = false
            errorMessage = nil
            scrollPosition.scrollTo(edge: .top)
            // 少しの間だけ目立たせる
            highlightedId = messageId
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { if highlightedId == messageId { highlightedId = nil } }
            }
            // 受信箱にあれば既読にする（最新までは読んでいないのでチャンネルの既読は進めない）
            await inbox.readShown(messageIds: messages.map(\.id), client: client)
            await loadUsers(client: client)
        } catch {
            // メッセージが消されているなどで見つからなければ、最新を表示する
            await load()
            sendError = "メッセージが見つかりませんでした"
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
    /// 過去を表示中に、いちばん新しいメッセージより後の30件を読み込む（下へスクロールしたとき）
    private func loadNewerPage() async {
        guard hasLoaded, !atEnd, !isLoadingNewer,
              let client = auth.client, let newest = messages.last
        else { return }
        isLoadingNewer = true
        defer { isLoadingNewer = false }
        do {
            let result: MessageHistory = try await client.post(
                "channel/get-history/\(channel.id)",
                body: HistoryRequest(direction: .newer, messageIdFrom: newest.id)
            )
            // 足す前の高さと位置を覚えておき、足した後に伸びた分だけずらす（onScrollGeometryChange で行う）
            scrollTracker.pendingAdjust = scrollTracker.metrics
            merge(result.history)
            imageDimensions.merge(result.imageDimensions ?? [:]) { _, new in new }
            atEnd = result.atEnd
            if atEnd {
                // 最新まで追いついたら、ふだんの表示と同じ扱いに戻す
                hasNewMessages = false
                await markLatestAsRead()
            }
            await loadUsers(client: client)
        } catch {
            scrollTracker.pendingAdjust = nil
        }
    }

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
        guard let client = auth.client else { return }
        // 表示したメッセージのうち、受信箱にあるもの（自分へのメンション・返信）も既読にする
        await inbox.readShown(messageIds: messages.map(\.id), client: client)
        // 過去を表示中は、最新まで読んだことにはしない
        guard atEnd, let newest = messages.last, channelStore.isJoined(channel.id) else { return }
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

    /// メッセージリンクを開く。同じチャンネルならその場で移動、別のチャンネルならそのチャンネルを開く
    private func openLink(_ ref: MessageLinkRef) {
        if ref.channelId == channel.id {
            Task { await jump(to: ref.messageId) }
        } else if let target = channelStore.allChannels.first(where: { $0.id == ref.channelId }) {
            linkedRoute = ChannelRoute(channel: target, messageId: ref.messageId)
        } else {
            sendError = "このチャンネルは表示できません"
        }
    }

    /// メッセージリンクのカードに出す内容
    private func linkPreview(for ref: MessageLinkRef) -> LinkedMessagePreview {
        let linked = linkedMessages[ref.messageId] ?? messages.first { $0.id == ref.messageId }
        var text = linked.map { formatter.format($0.content) }
        // 長い本文は 150 文字まで（Web 版と同じ）
        if let content = linked?.content, content.count > 150 {
            text = formatter.format(String(content.prefix(150)) + "…")
        }
        return LinkedMessagePreview(
            ref: ref,
            message: linked,
            isUnavailable: unavailableLinks.contains(ref.messageId),
            userName: linked.flatMap { users[$0.userId]?.name },
            channelName: channelStore.allChannels.first { $0.id == ref.channelId }?.name ?? "不明なチャンネル",
            text: text,
            iconURL: linked.flatMap { iconURL(for: $0.userId) }
        )
    }

    /// 本文中のメッセージリンク先を、まだ持っていなければ取ってくる
    private func loadLinkedMessages(client: APIClient) async {
        let known = Set(messages.map(\.id)).union(linkedMessages.keys).union(unavailableLinks)
        let missing = Set(messages.flatMap(\.messageLinks).map(\.messageId)).subtracting(known)
        for id in missing {
            if let message: Message = try? await client.get("message/\(id)") {
                linkedMessages[id] = message
            } else {
                unavailableLinks.insert(id)
            }
        }
    }

    /// 返信先・リンク先と、まだ知らないユーザーの情報をまとめて取ってくる
    private func loadUsers(client: APIClient) async {
        await loadReplies(client: client)
        await loadLinkedMessages(client: client)
        let allMessages = messages + Array(replyCache.values) + Array(linkedMessages.values)
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
        let rawDraft = draft
        // 入力欄の "@名前" をサーバーの形式 "@<ユーザーId>" に変えて送る
        let text = mentionDraft.encode(draft)
        let replyTarget = replyTarget
        let attachments = attachments
        draft = ""
        self.replyTarget = nil
        self.attachments = []
        isSending = true
        defer { isSending = false }
        do {
            // 1. 画像を1枚ずつアップロードして fileId をもらう
            var fileIds: [String] = []
            for attachment in attachments {
                let uploaded: UploadedFile = try await client.upload(
                    "message/file/upload",
                    fields: ["channelId": channel.id],
                    file: attachment.data,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType
                )
                fileIds.append(uploaded.id)
                // 縦横サイズは手元で分かっているので、表示用に覚えておく（ガタつき防止）
                imageDimensions[uploaded.id] = ImageDimension(width: attachment.width, height: attachment.height)
            }

            // 2. fileIds を付けてメッセージを送る
            // サーバーが保存したメッセージを返すので、それを一覧の最後に足す
            let sent: Message = try await client.post(
                "message/send",
                body: SendRequest(
                    channelId: channel.id,
                    message: text,
                    replyingMessageId: replyTarget?.id,
                    fileIds: fileIds.isEmpty ? nil : fileIds
                )
            )
            if !atEnd {
                // 過去を表示中に送ったら、最新を読み直して送ったメッセージを見せる
                await load()
            } else if !messages.contains(where: { $0.id == sent.id }) {
                // WebSocket の方が先に届いていることもあるので重複チェック
                messages.append(sent)
            }
            // 過去を読んでいる途中でも、送ったら最新（反転しているのでスクロールの先頭）へ戻る
            withAnimation {
                scrollPosition.scrollTo(edge: .top)
            }
            mentionDraft.reset()
            // 自分のメッセージも「最新」として数えられるので、既読を進めておく
            await markLatestAsRead()
            await loadUsers(client: client)
        } catch {
            // 失敗したら書いた文章・返信先・画像を戻す
            draft = rawDraft
            self.replyTarget = replyTarget
            self.attachments = attachments
            sendError = error.localizedDescription
        }
    }

    /// 写真アプリで選ばれたものを、送れる形にして添付に足す（最大4枚）
    private func addAttachments(from items: [PhotosPickerItem]) async {
        for item in items where attachments.count < 4 {
            if let attachment = await PendingAttachment.load(from: item) {
                attachments.append(attachment)
            } else {
                sendError = "画像を読み込めませんでした"
            }
        }
    }

    private func edit(_ message: Message, client: APIClient) async {
        let text = mentionDraft.encode(draft)
        isSending = true
        defer { isSending = false }
        do {
            let edit: MessageEdit = try await client.post(
                "message/edit",
                body: EditRequest(messageId: message.id, message: text)
            )
            // WebSocket でも届くが、返ってきた結果ですぐ反映する
            applyEdit(edit)
            mentionDraft.reset()
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

    private func searchMentionCandidates() async {
        guard let query = MentionDraft.query(in: draft), let client = auth.client else {
            mentionCandidates = []
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let found: [User]? = try? await client.get("user/list", query: [
            URLQueryItem(name: "username", value: query),
            URLQueryItem(name: "joinedChannel", value: channel.id),
            URLQueryItem(name: "length", value: "10"),
        ])
        guard !Task.isCancelled else { return }
        mentionCandidates = (found ?? []).filter { $0.name != nil }
    }

    private func cancelReplyOrEdit() {
        if editingMessage != nil {
            draft = ""
            mentionDraft.reset()
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
            // 過去を表示中は足さない（間が抜けた一覧になるため）。ボタンで知らせる
            guard atEnd else {
                hasNewMessages = true
                return
            }
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
        // 自分のリアクションは API の返り値ですでに反映しているので、他の人の分だけ反映する
        case .reactionAdded(let reaction) where reaction.channelId == channel.id && reaction.userId != auth.userId:
            updateMessage(reaction.messageId) { $0.addReaction(reaction, myUserId: auth.userId) }
        case .reactionDeleted(let reaction) where reaction.channelId == channel.id && reaction.userId != auth.userId:
            updateMessage(reaction.messageId) { $0.removeReaction(reaction, myUserId: auth.userId) }
        case .messageDeleted(let messageId, let channelId) where channelId == channel.id:
            messages.removeAll { $0.id == messageId }
        case .userUpdated(let update):
            // 名前を表示しているユーザーなら反映する
            if let user = users[update.id] {
                users[update.id] = user.updated(with: update)
            }
        case .connected:
            // つなぎ直したら、切れていた間のメッセージを取りに行く（最新を表示しているときだけ）
            if hasLoaded, atEnd {
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
    /// 添付ファイル。nil なら JSON に含めない
    let fileIds: [String]?
}

/// /message/file/upload の data。
/// バックエンドは insertFile の `.returning({ id })` をそのまま返すので `{ "fileId": { "id": "…" } }` の形になる
/// （Web 版も result.data.fileId.id で取り出している）
private struct UploadedFile: Decodable {
    struct FileId: Decodable {
        let id: String
    }

    private let fileId: FileId

    var id: String { fileId.id }
}

/// スクロールの高さと位置
private struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var visibleTop: CGFloat
}

/// スクロールの位置合わせ用の入れ物。
/// 値が変わるたびに画面を描き直す必要はないので、@Observable ではない普通のクラスにしている
/// （React の useRef と同じ使い方）
private final class ScrollTracker {
    var metrics = ScrollMetrics(contentHeight: 0, visibleTop: 0)
    /// 新しいメッセージを先頭に足す直前の状態。足した後の位置合わせが済んだら nil
    var pendingAdjust: ScrollMetrics?
}

/// プロフィールのシートを出す対象（.sheet(item:) には Identifiable な値が必要なので包む）
private struct ProfileTarget: Identifiable {
    let id: String
}

private struct ReactionRequest: Encodable {
    let messageId: String
    let channelId: String
    let emojiCode: String
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
    let onToggleReaction: (String) -> Void
    let onTapUser: () -> Void
    let onTapReply: () -> Void
    let linkPreviews: [LinkedMessagePreview]
    let onOpenLink: (MessageLinkRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply {
                ReplyQuote(reply: reply)
                    // アイコンの右側（本文の位置）にそろえる
                    .padding(.leading, 46)
                    // タップで返信先のメッセージへ移動
                    .contentShape(.rect)
                    .onTapGesture(perform: onTapReply)
            }
            content
        }
        // 文字の無い余白部分を長押ししても反応するよう、行全体を触れる範囲にする
        .contentShape(.rect)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            // URLSession.shared を使うので Cookie も自動で送られる。タップでプロフィール
            PresenceIcon(userId: message.userId, url: iconURL)
                .onTapGesture(perform: onTapUser)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(user?.name ?? "…")
                        .font(.subheadline.bold())
                        .onTapGesture(perform: onTapUser)
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
                // 本文中のメッセージリンク先の中身
                ForEach(linkPreviews) { preview in
                    MessageLinkCard(preview: preview) {
                        onOpenLink(preview.ref)
                    }
                }
                if let reactions = message.reactionSummary, !reactions.isEmpty {
                    ReactionBar(reactions: reactions, onToggle: onToggleReaction)
                }
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
