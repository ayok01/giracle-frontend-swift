import SwiftUI

/// チャンネルのメッセージ画面（見た目だけを受け持つ。データと処理は ChannelViewModel）
struct ChannelView: View {
    let channel: Channel
    /// 開いたときに表示したいメッセージ（受信箱から開いたときなど）。nil なら最新
    var initialMessageId: String?

    @Environment(AuthStore.self) private var auth
    @Environment(RealtimeClient.self) private var realtime
    @Environment(ChannelStore.self) private var channelStore
    @Environment(EmojiStore.self) private var emojiStore
    @Environment(InboxStore.self) private var inbox

    @State private var model: ChannelViewModel

    // MARK: - 画面だけの状態（スクロール・シート・キーボード）

    /// スクロール位置。送信後や移動後に最新（反転しているのでスクロールの先頭）へ戻すのに使う
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    /// ナビゲーションバー・入力欄・キーボードの分の余白（反転に合わせて自分で付ける）
    @State private var safeAreaInsets = EdgeInsets()
    @FocusState private var isInputFocused: Bool
    /// 長押しされて操作のシートを出しているメッセージ
    @State private var actionTarget: Message?
    /// シートが閉じきってから実行する操作（キーボードを出す・確認を出すなどはシートが閉じてからでないと効かない）
    @State private var pendingAction: (() -> Void)?
    /// 削除の確認を出しているメッセージ
    @State private var deleteTarget: Message?
    /// 絵文字ピッカーを開いているメッセージ
    @State private var pickerTarget: Message?
    /// プロフィールを開いているユーザー
    @State private var profileTarget: ProfileTarget?
    @State private var isMembersPresented = false
    /// 別のチャンネルのメッセージリンクを開くときの行き先
    @State private var linkedRoute: ChannelRoute?

    /// 長押しのシートに並べる、よく使う絵文字。
    /// コードは直接書かず、絵文字から引く（データ側でショートコードが変わっても追従できる）
    private static let quickReactionEmojis = ["👍", "❤️", "😂", "🎉", "👀", "🙏"]

    init(channel: Channel, initialMessageId: String? = nil) {
        self.channel = channel
        self.initialMessageId = initialMessageId
        _model = State(initialValue: ChannelViewModel(channel: channel))
    }

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .toolbar { toolbarContent }
            // チャンネル内ではタブバーを隠し、代わりに入力欄を置く
            .toolbarVisibility(.hidden, for: .tabBar)
            .task {
                model.attach(auth: auth, channelStore: channelStore, inbox: inbox)
                if let initialMessageId {
                    await jump(to: initialMessageId)
                } else {
                    await model.load()
                }
            }
            // "@…" を打っている間、チャンネルの参加者から候補を探す
            .task(id: MentionDraft.query(in: model.draft)) {
                await model.searchMentionCandidates()
            }
            // 画面を開いている間、WebSocket のイベントを受け取る
            .task {
                for await event in realtime.events() {
                    model.apply(event)
                }
            }
            .overlay { loadingOverlay }
            .alert(
                "うまくいきませんでした",
                isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(model.alertMessage ?? "")
            }
            // 削除の確認。confirmationDialog は付けた画面の位置から吹き出しで出るため、
            // 反転したスクロールだと位置がずれる。常に画面中央に出る alert を使う
            .alert(
                "メッセージを削除しますか？",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                presenting: deleteTarget
            ) { message in
                Button("削除", role: .destructive) {
                    Task { await model.delete(message) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { _ in
                Text("この操作は取り消せません")
            }
            .modifier(sheets)
            // 本文中のメンション・メッセージリンク（アプリ内 URL）をタップしたときの処理。
            // それ以外の URL は通常どおりブラウザで開く
            .environment(\.openURL, OpenURLAction { url in
                if let userId = MessageFormatter.userId(fromProfileURL: url) {
                    profileTarget = ProfileTarget(id: userId)
                    return .handled
                }
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
    }

    // MARK: - メッセージ一覧

    /// 一覧ごと上下反転したスクロール（チャットの定番。React Native の FlatList inverted と同じ）。
    /// スクロールの「先頭」が画面の下になるので、
    /// - 開いたとき何もしなくても最新（先頭）が見える
    /// - 古いメッセージは「末尾」に足される = 見ている場所より後ろなので位置がずれない
    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // 過去を表示中、先頭（= 画面の一番下）に来たら、それより新しいメッセージを読み込む見張り役
                if model.hasLoaded, !model.atEnd, !model.messages.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task(id: model.messages.last?.id) {
                            await model.loadNewerPage()
                        }
                }

                // 新しい順に並べる（先頭 = 画面の一番下）
                ForEach(model.messages.reversed()) { message in
                    Group {
                        if let system = message.systemContent {
                            SystemMessageRow(content: system, user: model.users[system.targetUserId])
                        } else {
                            messageRow(message)
                                // 移動先のメッセージは少しの間だけ色を付ける
                                .padding(model.highlightedId == message.id ? 6 : 0)
                                .background(
                                    model.highlightedId == message.id ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
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
                if model.hasLoaded, !model.atTop, !model.messages.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task(id: model.messages.first?.id) {
                            await model.loadOlder()
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
            let tracker = model.scrollTracker
            tracker.metrics = metrics
            // 先頭に足して中身が伸びたら、伸びた分だけずらして、見ていたメッセージを同じ場所に保つ
            if let before = tracker.pendingAdjust, metrics.contentHeight != before.contentHeight {
                tracker.pendingAdjust = nil
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
    }

    private func messageRow(_ message: Message) -> some View {
        MessageRow(
            message: message,
            text: model.formatter.format(message.content),
            user: model.users[message.userId],
            iconURL: model.iconURL(for: message.userId),
            reply: model.replyPreview(for: message),
            imageDimensions: model.imageDimensions,
            baseURL: auth.client?.baseURL,
            linkPreviews: message.messageLinks.map(model.linkPreview(for:)),
            onToggleReaction: { code in
                Task { await model.toggleReaction(code, on: message) }
            },
            onTapUser: { profileTarget = ProfileTarget(id: message.userId) },
            onTapReply: {
                if let replyId = message.replyingMessageId {
                    Task { await jump(to: replyId) }
                }
            },
            onOpenLink: openLink
        )
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if !model.hasLoaded {
            ProgressView()
        } else if let errorMessage = model.errorMessage {
            ContentUnavailableView(
                "読み込めませんでした",
                systemImage: "wifi.exclamationmark",
                description: Text(errorMessage)
            )
        } else if model.messages.isEmpty {
            ContentUnavailableView("メッセージはまだありません", systemImage: "bubble")
        }
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    // MARK: - 下の入力欄

    /// 入力欄（か参加ボタン）と、過去を表示中なら「最新のメッセージへ」ボタン
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if !model.atEnd {
                Button(
                    model.hasNewMessages ? "新しいメッセージがあります" : "最新のメッセージへ",
                    systemImage: "arrow.down"
                ) {
                    Task {
                        await model.load()
                        scrollPosition.scrollTo(edge: .top)
                    }
                }
                .buttonStyle(.glass)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputArea
        }
        .animation(.snappy, value: model.atEnd)
    }

    /// 参加済みなら入力欄、未参加なら参加ボタン
    @ViewBuilder
    private var inputArea: some View {
        if model.isJoined {
            MessageInputBar(
                text: $model.draft,
                isSending: model.isSending,
                banner: model.inputBanner,
                focus: $isInputFocused,
                onCancelBanner: model.cancelReplyOrEdit,
                attachments: model.attachments,
                // 編集中は画像を足せない（編集 API は本文しか変えられない）
                onPickPhotos: model.editingMessage == nil ? { items in
                    Task { await model.addAttachments(from: items) }
                } : nil,
                onRemoveAttachment: model.removeAttachment,
                mentionCandidates: model.mentionCandidates,
                iconURL: model.iconURL(for:),
                onSelectMention: model.selectMention
            ) {
                Task {
                    if await model.send() {
                        // 過去を読んでいる途中でも、送ったら最新（反転しているのでスクロールの先頭）へ戻る
                        withAnimation { scrollPosition.scrollTo(edge: .top) }
                    }
                }
            }
        } else if channelStore.hasLoaded {
            Button("このチャンネルに参加", systemImage: "plus") {
                Task { await model.join() }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.bottom, 8)
        }
    }

    // MARK: - シート

    private var sheets: ChannelSheets {
        ChannelSheets(
            actionTarget: $actionTarget,
            pickerTarget: $pickerTarget,
            profileTarget: $profileTarget,
            isMembersPresented: $isMembersPresented,
            channel: channel,
            onDismissAction: {
                pendingAction?()
                pendingAction = nil
            },
            actionSheet: { message in AnyView(actionSheet(for: message)) },
            onPickEmoji: { code, message in
                Task { await model.toggleReaction(code, on: message) }
            }
        )
    }

    /// 長押しで出る操作のシート
    private func actionSheet(for message: Message) -> some View {
        List {
            Section {
                messageRow(message)
                    .allowsHitTesting(false)
            }
            if model.isJoined {
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

    /// 長押しのシートの、よく使う絵文字の列と「その他」ボタン
    private func quickReactions(for message: Message) -> some View {
        HStack {
            ForEach(Self.quickReactionEmojis, id: \.self) { emoji in
                if let code = emojiStore.code(for: emoji) {
                    Button {
                        closeSheet {
                            Task { await model.toggleReaction(code, on: message) }
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

    /// 操作のシートのボタン
    @ViewBuilder
    private func messageMenu(for message: Message) -> some View {
        let isMine = message.userId == model.myUserId

        if model.isJoined {
            Button("返信", systemImage: "arrowshape.turn.up.left") {
                closeSheet {
                    model.startReply(to: message)
                    isInputFocused = true
                }
            }
        }
        Button("コピー", systemImage: "doc.on.doc") {
            // @<userId> などは名前に置き換えた、見たままの文字をコピーする
            UIPasteboard.general.string = model.plainText(of: message)
            closeSheet {}
        }
        Button("リンクをコピー", systemImage: "link") {
            // Web 版（HoverMenu.tsx）と同じ形式。貼り付けて送ると「#チャンネル名 のメッセージ」になる
            UIPasteboard.general.string = "&<\(message.channelId):\(message.id)>"
            closeSheet {}
        }
        if model.isJoined, isMine {
            Button("編集", systemImage: "pencil") {
                closeSheet {
                    model.startEdit(message)
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

    // MARK: - 移動

    /// 指定したメッセージへ移動して、最新の位置（画面の一番下）を表示する
    private func jump(to messageId: String) async {
        await model.jump(to: messageId)
        scrollPosition.scrollTo(edge: .top)
    }

    /// メッセージリンクを開く。同じチャンネルならその場で移動、別のチャンネルならそのチャンネルを開く
    private func openLink(_ ref: MessageLinkRef) {
        if ref.channelId == channel.id {
            Task { await jump(to: ref.messageId) }
        } else if let target = channelStore.allChannels.first(where: { $0.id == ref.channelId }) {
            linkedRoute = ChannelRoute(channel: target, messageId: ref.messageId)
        } else {
            model.alertMessage = "このチャンネルは表示できません"
        }
    }
}

/// チャンネル画面のシート（長押しの操作・絵文字ピッカー・プロフィール・メンバー）をまとめた modifier。
/// body が長くなりすぎると Swift の型チェックが重くなるので、シートの部分を切り出している
private struct ChannelSheets: ViewModifier {
    @Binding var actionTarget: Message?
    @Binding var pickerTarget: Message?
    @Binding var profileTarget: ProfileTarget?
    @Binding var isMembersPresented: Bool
    let channel: Channel
    let onDismissAction: () -> Void
    let actionSheet: (Message) -> AnyView
    let onPickEmoji: (String, Message) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $actionTarget, onDismiss: onDismissAction) { message in
                actionSheet(message)
            }
            // 長押しが決まったら「ブルッ」と振動させる
            .sensoryFeedback(.impact, trigger: actionTarget?.id) { _, newValue in
                newValue != nil
            }
            // すべての絵文字から選ぶピッカー
            .sheet(item: $pickerTarget) { message in
                EmojiPickerView { code in
                    onPickEmoji(code, message)
                }
            }
            .sheet(item: $profileTarget) { target in
                ProfileView(userId: target.id)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isMembersPresented) {
                ChannelMembersView(channel: channel)
                    .presentationDetents([.medium, .large])
            }
    }
}

/// プロフィールのシートを出す対象（.sheet(item:) には Identifiable な値が必要なので包む）
private struct ProfileTarget: Identifiable {
    let id: String
}
