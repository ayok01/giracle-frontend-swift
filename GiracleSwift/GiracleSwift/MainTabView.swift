import SwiftUI

/// サインイン後の画面。下のタブバーで切り替える
struct MainTabView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(RealtimeClient.self) private var realtime
    /// サインインごとに作り直されるよう、この画面で持つ
    @State private var channelStore = ChannelStore()

    var body: some View {
        TabView {
            Tab("チャンネル", systemImage: "bubble.left.and.bubble.right") {
                ChannelListView()
            }
            Tab("受信箱", systemImage: "tray") {
                // 後のステップで作る
                NavigationStack {
                    ContentUnavailableView("準備中", systemImage: "tray")
                        .navigationTitle("受信箱")
                }
            }
            Tab("設定", systemImage: "gearshape") {
                SettingsView()
            }
        }
        // 下にスクロールするとタブバーが小さくなる
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(channelStore)
        // サインイン中はずっと WebSocket につなぐ。サインアウトでこの画面が消えると切れる
        .task {
            guard let baseURL = auth.client?.baseURL else { return }
            await realtime.run(baseURL: baseURL)
        }
    }
}

#Preview {
    MainTabView()
        .environment(AuthStore())
        .environment(RealtimeClient())
}
