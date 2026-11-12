import SwiftUI

/// 見られる全チャンネルを探して、参加・退出する画面（Web 版の channel-browser）
struct ChannelBrowserView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(ChannelStore.self) private var channelStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    /// 通信中のチャンネル（ボタンをくるくるにする）
    @State private var busyIds: Set<String> = []
    @State private var errorMessage: String?

    private var filteredChannels: [Channel] {
        guard !searchText.isEmpty else { return channelStore.allChannels }
        return channelStore.allChannels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filteredChannels) { channel in
                HStack {
                    ChannelRow(channel: channel)
                    joinButton(for: channel)
                }
            }
            .navigationTitle("チャンネルを探す")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "チャンネルを検索")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了", systemImage: "checkmark") { dismiss() }
                }
            }
            .overlay {
                if !searchText.isEmpty, filteredChannels.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .alert(
                "操作できませんでした",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func joinButton(for channel: Channel) -> some View {
        if busyIds.contains(channel.id) {
            ProgressView()
        } else if channelStore.isJoined(channel.id) {
            Button("退出") { Task { await toggle(channel) } }
                .buttonStyle(.glass)
        } else {
            Button("参加") { Task { await toggle(channel) } }
                .buttonStyle(.glassProminent)
        }
    }

    private func toggle(_ channel: Channel) async {
        guard let client = auth.client else { return }
        busyIds.insert(channel.id)
        defer { busyIds.remove(channel.id) }
        do {
            if channelStore.isJoined(channel.id) {
                try await channelStore.leave(channel.id, client: client)
            } else {
                try await channelStore.join(channel.id, client: client)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ChannelBrowserView()
        .environment(AuthStore())
        .environment(ChannelStore())
}
