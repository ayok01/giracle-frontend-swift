import SwiftUI

/// サインイン後の画面。下のタブバーで切り替える
struct MainTabView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(RealtimeClient.self) private var realtime
    /// サインインごとに作り直されるよう、この画面で持つ
    @State private var channelStore = ChannelStore()
    @State private var emojiStore = EmojiStore()
    @State private var inboxStore = InboxStore()
    @State private var presenceStore = PresenceStore()

    var body: some View {
        TabView {
            Tab("チャンネル", systemImage: "bubble.left.and.bubble.right") {
                ChannelListView()
            }
            // 未読のあるチャンネルの数をタブに赤い数字で出す（0 のときは出ない）
            .badge(channelStore.unreadIds.count)
            Tab("受信箱", systemImage: "tray") {
                InboxView()
            }
            .badge(inboxStore.items.count)
            Tab("設定", systemImage: "gearshape") {
                SettingsView()
            }
        }
        // 下にスクロールするとタブバーが小さくなる
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(channelStore)
        .environment(emojiStore)
        .environment(inboxStore)
        .environment(presenceStore)
        .task {
            guard let client = auth.client else { return }
            await inboxStore.load(client: client)
        }
        .task {
            guard let client = auth.client else { return }
            await presenceStore.load(client: client, myUserId: auth.userId)
        }
        // チャンネル名は受信箱でも使うので、どのタブを先に開いても読み込まれるようにする
        .task {
            guard !channelStore.hasLoaded, let client = auth.client, let myUserId = auth.userId else { return }
            await channelStore.load(client: client, myUserId: myUserId)
        }
        // 絵文字データ（Web 版と同じ CDN）とカスタム絵文字を読み込む
        .task {
            await emojiStore.load()
        }
        .task {
            guard let client = auth.client else { return }
            await emojiStore.loadCustomEmojis(client: client)
        }
        // サインイン中はずっと WebSocket につなぐ。サインアウトでこの画面が消えると切れる
        .task {
            guard let baseURL = auth.client?.baseURL else { return }
            await realtime.run(baseURL: baseURL)
        }
        // どの画面を開いていても未読の印を更新できるよう、ここでイベントを受け取る
        .task {
            for await event in realtime.events() {
                guard let client = auth.client else { continue }
                channelStore.apply(event, myUserId: auth.userId, client: client)
                inboxStore.apply(event, client: client)
                presenceStore.apply(event, client: client, myUserId: auth.userId)
                if case .serverConfigUpdated = event {
                    Task { await auth.loadServerConfig() }
                }
            }
        }
    }
}

#Preview {
    MainTabView()
        .environment(AuthStore())
        .environment(RealtimeClient())
}
