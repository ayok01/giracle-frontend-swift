import SwiftUI

/// 参加中のチャンネル一覧（Slack のサイドバーに相当）
struct ChannelListView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(ChannelStore.self) private var channelStore

    @State private var isBrowserPresented = false
    /// 編集モード（EditButton で切り替わる）
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                ForEach(channelStore.joinedChannels) { channel in
                    // タップすると channel を「行き先の値」として積む
                    NavigationLink(value: channel) {
                        ChannelRow(channel: channel, isUnread: channelStore.isUnread(channel.id))
                    }
                }
                // 編集モードのときだけ並べ替えを有効にする。
                // 常に有効だと長押しドラッグと NavigationLink がぶつかって落ちることがある
                .onMove(perform: moveAction)
            }
            .environment(\.editMode, $editMode)
            // Channel が積まれたらこの画面を出す（ルーティングの定義）
            .navigationDestination(for: Channel.self) { channel in
                ChannelView(channel: channel)
            }
            // サーバー名をタイトルに（Slack のワークスペース名と同じ位置）
            .navigationTitle(auth.serverConfig?.name ?? "チャンネル")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "完了" : "並べ替え") {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("チャンネルを探す", systemImage: "plus") {
                        isBrowserPresented = true
                    }
                }
            }
            .sheet(isPresented: $isBrowserPresented) {
                ChannelBrowserView()
            }
            .refreshable { await load() }
            .task {
                if !channelStore.hasLoaded { await load() }
            }
            .overlay {
                if !channelStore.hasLoaded {
                    ProgressView()
                } else if let errorMessage = channelStore.errorMessage, channelStore.allChannels.isEmpty {
                    ContentUnavailableView(
                        "読み込めませんでした",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else if channelStore.joinedChannels.isEmpty {
                    ContentUnavailableView {
                        Label("参加中のチャンネルはありません", systemImage: "bubble.left.and.bubble.right")
                    } actions: {
                        Button("チャンネルを探す") { isBrowserPresented = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }

    /// 編集モードなら並べ替え処理、そうでなければ nil（＝並べ替え不可）
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard editMode.isEditing else { return nil }
        return { source, destination in
            channelStore.move(fromOffsets: source, toOffset: destination)
        }
    }

    private func load() async {
        guard let client = auth.client, let myUserId = auth.userId else { return }
        await channelStore.load(client: client, myUserId: myUserId)
    }
}

struct ChannelRow: View {
    let channel: Channel
    var isUnread = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.headline)
                    // 未読があれば太く、なければ少し細く（Slack と同じ考え方）
                    .fontWeight(isUnread ? .bold : .regular)
                if !channel.description.isEmpty {
                    Text(channel.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if isUnread {
                Circle()
                    .fill(.tint)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel("未読あり")
            }
            if channel.isArchived {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ChannelListView()
        .environment(AuthStore())
        .environment(ChannelStore())
}
