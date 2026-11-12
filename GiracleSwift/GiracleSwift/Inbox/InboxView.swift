import SwiftUI

/// 受信箱（自分へのメンション・返信の一覧）
struct InboxView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(InboxStore.self) private var inbox
    @Environment(ChannelStore.self) private var channelStore
    @Environment(RealtimeClient.self) private var realtime

    /// Web 版と同じく「日付ごと」「チャンネルごと」を切り替えられる
    enum Grouping: String, CaseIterable {
        case date = "日付"
        case channel = "チャンネル"
    }

    @State private var grouping: Grouping = .date
    /// 開いている画面（NavigationStack の履歴。React Router の history に近い）
    @State private var path: [ChannelRoute] = []
    /// userId → User（名前とメンションの表示用）
    @State private var users: [String: User] = [:]
    @State private var isConfirmingClear = false

    private struct InboxSection: Identifiable {
        let id: String
        let title: String
        let items: [InboxItem]
    }

    private var sections: [InboxSection] {
        switch grouping {
        case .date:
            let byDay = Dictionary(grouping: inbox.items) { Calendar.current.startOfDay(for: $0.happenedAt) }
            return byDay.keys.sorted(by: >).map { day in
                InboxSection(id: day.description, title: dayTitle(day), items: byDay[day] ?? [])
            }
        case .channel:
            let byChannel = Dictionary(grouping: inbox.items) { $0.message.channelId }
            return byChannel
                .map { channelId, items in
                    InboxSection(id: channelId, title: channelName(channelId), items: items)
                }
                // 新しい通知があるチャンネルほど上に
                .sorted { ($0.items.first?.happenedAt ?? .distantPast) > ($1.items.first?.happenedAt ?? .distantPast) }
        }
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
                Picker("まとめ方", selection: $grouping) {
                    ForEach(Grouping.allCases, id: \.self) { grouping in
                        Text(grouping.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            row(for: item)
                        }
                    }
                }
            }
            .navigationTitle("受信箱")
            .navigationDestination(for: ChannelRoute.self) { route in
                // 通知のメッセージの位置を開く
                ChannelView(channel: route.channel, initialMessageId: route.messageId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("すべて既読", systemImage: "checkmark.circle") {
                        isConfirmingClear = true
                    }
                    .disabled(inbox.items.isEmpty)
                }
            }
            .alert("すべて既読にしますか？", isPresented: $isConfirmingClear) {
                Button("すべて既読", role: .destructive) {
                    Task { await clear() }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("受信箱の通知がすべて消えます")
            }
            .overlay {
                if inbox.items.isEmpty {
                    ContentUnavailableView(
                        "通知はありません",
                        systemImage: "tray",
                        description: Text("メンションや返信をされるとここに表示されます")
                    )
                }
            }
            .refreshable {
                if let client = auth.client {
                    await inbox.load(client: client)
                }
            }
            // 通知が増えたら、まだ知らないユーザーの名前を取ってくる
            .task(id: inbox.items.map(\.id)) {
                await loadUsers()
            }
            // 名前が変わったら反映する
            .task {
                for await event in realtime.events() {
                    if case .userUpdated(let update) = event, let user = users[update.id] {
                        users[update.id] = user.updated(with: update)
                    }
                }
            }
        }
    }

    private func row(for item: InboxItem) -> some View {
        Button {
            open(item)
        } label: {
            MessageSummaryRow(
                message: item.message,
                user: users[item.message.userId],
                channelName: channelName(item.message.channelId),
                text: formatter.format(item.message.content),
                iconURL: auth.client?.baseURL.appending(path: "user/icon/\(item.message.userId)"),
                label: item.kind == .reply
                    ? ("返信", "arrowshape.turn.up.left.fill")
                    : ("メンション", "at")
            )
        }
        .buttonStyle(.plain)
        // 左にスワイプして既読（メールアプリと同じ操作）
        .swipeActions {
            Button("既読", systemImage: "checkmark") {
                Task { await read(item) }
            }
            .tint(.accentColor)
        }
    }

    /// タップでそのメッセージの位置を開き、既読にする
    private func open(_ item: InboxItem) {
        if let channel = channelStore.allChannels.first(where: { $0.id == item.message.channelId }) {
            path.append(ChannelRoute(channel: channel, messageId: item.message.id))
        }
        Task { await read(item) }
    }

    private func read(_ item: InboxItem) async {
        guard let client = auth.client else { return }
        await inbox.read(messageId: item.message.id, client: client)
    }

    private func clear() async {
        guard let client = auth.client else { return }
        try? await inbox.clear(client: client)
    }

    private func loadUsers() async {
        guard let client = auth.client else { return }
        let unknownIds = Set(inbox.items.flatMap(\.message.relatedUserIds)).subtracting(users.keys)
        for userId in unknownIds {
            if let user: User = try? await client.get("user/info/\(userId)") {
                users[userId] = user
            }
        }
    }

    private func channelName(_ channelId: String) -> String {
        channelStore.allChannels.first { $0.id == channelId }?.name ?? "不明なチャンネル"
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今日" }
        if Calendar.current.isDateInYesterday(day) { return "昨日" }
        return day.formatted(.dateTime.month().day().weekday())
    }
}
