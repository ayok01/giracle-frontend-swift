import SwiftUI
import PhotosUI

/// 入力・送信・編集・削除・リアクション・参加
extension ChannelViewModel {
    // MARK: - 返信・編集の開始と取り消し

    func startReply(to message: Message) {
        editingMessage = nil
        replyTarget = message
    }

    func startEdit(_ message: Message) {
        replyTarget = nil
        editingMessage = message
        // "@<ユーザーId>" は "@名前" に戻して入力欄に入れる
        mentionDraft.reset()
        draft = mentionDraft.decode(message.content, users: users)
    }

    func cancelReplyOrEdit() {
        if editingMessage != nil {
            draft = ""
            mentionDraft.reset()
        }
        editingMessage = nil
        replyTarget = nil
    }

    /// 入力欄の上に出す「返信中」「編集中」
    var inputBanner: InputBanner? {
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

    // MARK: - 送信

    /// 入力欄の内容を送る（編集中なら編集を保存する）。送れたら true
    @discardableResult
    func send() async -> Bool {
        guard let client else { return false }
        if let editingMessage {
            return await edit(editingMessage, client: client)
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
            mentionDraft.reset()
            // 自分のメッセージも「最新」として数えられるので、既読を進めておく
            await markLatestAsRead()
            await loadRelated()
            return true
        } catch {
            // 失敗したら書いた文章・返信先・画像を戻す
            draft = rawDraft
            self.replyTarget = replyTarget
            self.attachments = attachments
            alertMessage = error.localizedDescription
            return false
        }
    }

    private func edit(_ message: Message, client: APIClient) async -> Bool {
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
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ message: Message) async {
        guard let client else { return }
        do {
            try await client.delete("message/delete", body: ["messageId": message.id])
            // WebSocket でも消えるが、すぐ反映させる
            messages.removeAll { $0.id == message.id }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - 添付画像

    /// 写真アプリで選ばれたものを、送れる形にして添付に足す（最大4枚）
    func addAttachments(from items: [PhotosPickerItem]) async {
        for item in items where attachments.count < 4 {
            if let attachment = await PendingAttachment.load(from: item) {
                attachments.append(attachment)
            } else {
                alertMessage = "画像を読み込めませんでした"
            }
        }
    }

    func removeAttachment(_ attachment: PendingAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    // MARK: - メンションの候補

    /// "@…" を打っている間、チャンネルの参加者から候補を探す（0.2 秒の debounce。Web 版と同じ）
    func searchMentionCandidates() async {
        guard let query = MentionDraft.query(in: draft), let client else {
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

    func selectMention(_ user: User) {
        mentionDraft.insert(user, into: &draft)
        mentionCandidates = []
    }

    // MARK: - リアクション

    /// 自分が付けていれば外し、付けていなければ付ける（Web 版と同じ動き）
    func toggleReaction(_ code: String, on message: Message) async {
        guard let client else { return }
        // 最新の状態で判定する（シートを開いている間に変わっているかもしれない）
        let current = messages.first { $0.id == message.id } ?? message
        let body = ReactionRequest(messageId: message.id, channelId: message.channelId, emojiCode: code)
        do {
            if current.reactionSummary?.contains(where: { $0.emojiCode == code && $0.includingYou }) == true {
                let reaction: Reaction = try await client.delete("message/delete-emoji-reaction", body: body)
                updateMessage(message.id) { $0.removeReaction(reaction, myUserId: myUserId) }
            } else {
                guard current.myReactionCount < 10 else {
                    alertMessage = "同一ユーザーによるリアクションは10個までです。"
                    return
                }
                let reaction: Reaction = try await client.post("message/emoji-reaction", body: body)
                updateMessage(message.id) { $0.addReaction(reaction, myUserId: myUserId) }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - 参加

    func join() async {
        guard let client else { return }
        do {
            try await channelStore?.join(channel.id, client: client)
            // 「参加しました」のお知らせを表示するため読み直す
            await load()
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
