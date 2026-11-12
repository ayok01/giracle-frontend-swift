import SwiftUI
import Observation

/// チャンネル画面のデータと処理（React でいうカスタムフック useChannel() に相当）。
/// 画面（ChannelView）は見た目だけを受け持ち、読み込み・送信・WebSocket の反映などはここで行う。
/// 入力・送信まわりは ChannelViewModel+Compose.swift に分けている
@Observable
final class ChannelViewModel {
    let channel: Channel

    // MARK: - 依存するストア（画面の environment から attach で受け取る）

    @ObservationIgnored private var auth: AuthStore?
    @ObservationIgnored var channelStore: ChannelStore?
    @ObservationIgnored private var inbox: InboxStore?

    var client: APIClient? { auth?.client }
    var myUserId: String? { auth?.userId }

    // MARK: - メッセージ一覧の状態

    /// 古い順（画面の上から下へ並べる順）
    var messages: [Message] = []
    /// userId → User。名前を表示するために取ってきたユーザーを覚えておく
    var users: [String: User] = [:]
    /// 画像ファイルId → 縦横サイズ（履歴を読み込むたびに足していく）
    var imageDimensions: [String: ImageDimension] = [:]
    var hasLoaded = false
    var errorMessage: String?
    /// いちばん古いメッセージまで読み込んだか
    var atTop = false
    /// 最新のメッセージまで表示しているか。指定したメッセージへ移動したときは false（それより新しいものは読み込んでいない）
    var atEnd = true
    /// 過去を表示している間に、新しいメッセージが届いたか
    var hasNewMessages = false
    /// 移動先として目立たせているメッセージ
    var highlightedId: String?
    /// 返信先が一覧に読み込まれていないとき用に、個別に取ってきたメッセージ
    var replyCache: [String: Message] = [:]
    /// メッセージリンク先のメッセージ（メッセージId → メッセージ）
    var linkedMessages: [String: Message] = [:]
    /// 取れなかったメッセージリンク先（削除済み・権限なし）
    var unavailableLinks: Set<String> = []
    /// 画面に出すエラー（アラート）
    var alertMessage: String?

    @ObservationIgnored private var isLoadingOlder = false
    @ObservationIgnored private var isLoadingNewer = false
    /// スクロールの位置合わせ用（新しいメッセージを先頭に足す直前の状態を画面に渡す）
    @ObservationIgnored let scrollTracker = ScrollTracker()

    // MARK: - 入力欄の状態（処理は ChannelViewModel+Compose.swift）

    var draft = ""
    /// 送信前の添付画像
    var attachments: [PendingAttachment] = []
    /// 入力中のメンション（"@名前" ⇄ "@<ユーザーId>" の変換）
    var mentionDraft = MentionDraft()
    /// "@" 入力中に出す候補
    var mentionCandidates: [User] = []
    var isSending = false
    /// 返信しようとしているメッセージ
    var replyTarget: Message?
    /// 編集しているメッセージ
    var editingMessage: Message?

    init(channel: Channel) {
        self.channel = channel
    }

    /// 画面が表示されたときに、environment のストアを受け取る
    func attach(auth: AuthStore, channelStore: ChannelStore, inbox: InboxStore) {
        self.auth = auth
        self.channelStore = channelStore
        self.inbox = inbox
    }

    var isJoined: Bool {
        channelStore?.isJoined(channel.id) ?? false
    }

    // MARK: - 読み込み

    /// 最新の30件を読み込む
    func load() async {
        guard let client else { return }
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
            await loadRelated()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 指定したメッセージへ移動する。
    /// そのメッセージを「いちばん新しい位置」として、それ以前の30件を読み込む。
    /// 反転した一覧ではいちばん新しい位置が最初から画面の下に見えるので、スクロールさせずに表示できる
    /// （iOS 27 の LazyVStack では、まだ描画していない行への scrollTo が当てにならないため）
    func jump(to messageId: String) async {
        guard let client else { return }
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
            // 少しの間だけ目立たせる
            highlightedId = messageId
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation { if highlightedId == messageId { highlightedId = nil } }
            }
            // 受信箱にあれば既読にする（最新までは読んでいないのでチャンネルの既読は進めない）
            await inbox?.readShown(messageIds: messages.map(\.id), client: client)
            await loadRelated()
        } catch {
            // メッセージが消されているなどで見つからなければ、最新を表示する
            await load()
            alertMessage = "メッセージが見つかりませんでした"
        }
    }

    /// いちばん古いメッセージより前の30件を読み込む（上へスクロールしたとき）
    func loadOlder() async {
        guard hasLoaded, !atTop, !isLoadingOlder,
              let client, let oldest = messages.first
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
            await loadRelated()
        } catch {
            // 失敗しても、見張り役がもう一度表示されたときにやり直す
        }
    }

    /// 過去を表示中に、いちばん新しいメッセージより後の30件を読み込む（下へスクロールしたとき）
    func loadNewerPage() async {
        guard hasLoaded, !atEnd, !isLoadingNewer,
              let client, let newest = messages.last
        else { return }
        isLoadingNewer = true
        defer { isLoadingNewer = false }
        do {
            let result: MessageHistory = try await client.post(
                "channel/get-history/\(channel.id)",
                body: HistoryRequest(direction: .newer, messageIdFrom: newest.id)
            )
            // 足す前の高さと位置を覚えておき、足した後に伸びた分だけずらす（画面の onScrollGeometryChange で行う）
            scrollTracker.pendingAdjust = scrollTracker.metrics
            merge(result.history)
            imageDimensions.merge(result.imageDimensions ?? [:]) { _, new in new }
            atEnd = result.atEnd
            if atEnd {
                // 最新まで追いついたら、ふだんの表示と同じ扱いに戻す
                hasNewMessages = false
                await markLatestAsRead()
            }
            await loadRelated()
        } catch {
            scrollTracker.pendingAdjust = nil
        }
    }

    /// WebSocket が切れていた間のメッセージを取り直す
    private func catchUp() async {
        guard let client, let newest = messages.last else { return }
        do {
            let result: MessageHistory = try await client.post(
                "channel/get-history/\(channel.id)",
                body: HistoryRequest(direction: .newer, messageIdFrom: newest.id)
            )
            if result.atEnd {
                merge(result.history)
                imageDimensions.merge(result.imageDimensions ?? [:]) { _, new in new }
                await loadRelated()
            } else {
                // 30件より多く取りこぼしたので、最新から読み直す
                await load()
            }
        } catch {}
    }

    /// いちばん新しいメッセージまで読んだことにする（参加中のチャンネルだけ）
    func markLatestAsRead() async {
        guard let client else { return }
        // 表示したメッセージのうち、受信箱にあるもの（自分へのメンション・返信）も既読にする
        await inbox?.readShown(messageIds: messages.map(\.id), client: client)
        // 過去を表示中は、最新まで読んだことにはしない
        guard atEnd, let newest = messages.last, isJoined else { return }
        await channelStore?.markAsRead(newest, client: client)
    }

    /// 取得したメッセージを今の一覧に混ぜる。
    /// 基準にしたメッセージ自身も返ってくるので、id で重複を除いてから古い順に並べ直す
    func merge(_ incoming: [Message]) {
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in incoming {
            byId[message.id] = message
        }
        messages = byId.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// 一覧の中の1件を書き換える
    func updateMessage(_ id: String, _ change: (inout Message) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            change(&messages[index])
        }
    }

    // MARK: - 表示に必要な関連データ（返信先・リンク先・ユーザー）

    /// 返信先・リンク先と、まだ知らないユーザーの情報をまとめて取ってくる
    func loadRelated() async {
        guard let client else { return }
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

    // MARK: - 表示用に組み立てた値

    var formatter: MessageFormatter {
        MessageFormatter(
            users: users,
            channels: Dictionary(uniqueKeysWithValues: (channelStore?.allChannels ?? []).map { ($0.id, $0) }),
            myUserId: myUserId
        )
    }

    func iconURL(for userId: String) -> URL? {
        client?.baseURL.appending(path: "user/icon/\(userId)")
    }

    func channelName(_ channelId: String) -> String {
        channelStore?.allChannels.first { $0.id == channelId }?.name ?? "不明なチャンネル"
    }

    /// メンションなどを名前に置き換えた、見たままの文字
    func plainText(of message: Message) -> String {
        let text = String(formatter.format(message.content).characters)
        if text.isEmpty, let file = message.files?.first {
            return file.isImage ? "画像" : file.actualFileName
        }
        return text
    }

    /// 返信先の表示に使う「返信先メッセージとその送信者」
    func replyPreview(for message: Message) -> ReplyPreview? {
        guard let replyId = message.replyingMessageId else { return nil }
        let target = messages.first { $0.id == replyId } ?? replyCache[replyId]
        return ReplyPreview(
            name: target.flatMap { users[$0.userId]?.name },
            excerpt: target.map { plainText(of: $0) } ?? "読み込み中…"
        )
    }

    /// メッセージリンクのカードに出す内容
    func linkPreview(for ref: MessageLinkRef) -> LinkedMessagePreview {
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
            channelName: channelName(ref.channelId),
            text: text,
            iconURL: linked.flatMap { iconURL(for: $0.userId) }
        )
    }

    // MARK: - WebSocket

    /// WebSocket で届いたイベントをこのチャンネルの一覧に反映する
    func apply(_ event: RealtimeEvent) {
        switch event {
        case .messageSent(let message) where message.channelId == channel.id:
            // 過去を表示中は足さない（間が抜けた一覧になるため）。ボタンで知らせる
            guard atEnd else {
                hasNewMessages = true
                return
            }
            guard !messages.contains(where: { $0.id == message.id }) else { return }
            messages.append(message)
            Task {
                await loadRelated()
                // 開いている間に届いたものはその場で読んだことにする
                await markLatestAsRead()
            }
        case .messageUpdated(let message) where message.channelId == channel.id:
            updateMessage(message.id) { $0 = message }
        case .messageEdited(let edit) where edit.channelId == channel.id:
            applyEdit(edit)
        // 自分のリアクションは API の返り値ですでに反映しているので、他の人の分だけ反映する
        case .reactionAdded(let reaction) where reaction.channelId == channel.id && reaction.userId != myUserId:
            updateMessage(reaction.messageId) { $0.addReaction(reaction, myUserId: myUserId) }
        case .reactionDeleted(let reaction) where reaction.channelId == channel.id && reaction.userId != myUserId:
            updateMessage(reaction.messageId) { $0.removeReaction(reaction, myUserId: myUserId) }
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
                Task { await catchUp() }
            }
        default:
            // 他のチャンネルのイベント
            break
        }
    }

    /// 編集の結果を一覧（と返信先のキャッシュ）に反映する
    func applyEdit(_ edit: MessageEdit) {
        updateMessage(edit.id) { $0.apply(edit) }
        replyCache[edit.id]?.apply(edit)
    }
}

/// スクロールの高さと位置
struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var visibleTop: CGFloat
}

/// スクロールの位置合わせ用の入れ物。
/// 値が変わるたびに画面を描き直す必要はないので、@Observable ではない普通のクラスにしている
/// （React の useRef と同じ使い方）
final class ScrollTracker {
    var metrics = ScrollMetrics(contentHeight: 0, visibleTop: 0)
    /// 新しいメッセージを先頭に足す直前の状態。足した後の位置合わせが済んだら nil
    var pendingAdjust: ScrollMetrics?
}
