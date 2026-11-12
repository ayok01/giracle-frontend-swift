import SwiftUI

/// チャンネルの参加者一覧（オンライン / オフラインに分けて表示）
struct ChannelMembersView: View {
    let channel: Channel

    @Environment(AuthStore.self) private var auth
    @Environment(PresenceStore.self) private var presence
    @Environment(\.dismiss) private var dismiss

    @State private var members: [User] = []
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var profileTarget: MemberProfileTarget?

    private var filtered: [User] {
        let sorted = members.sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter { ($0.name ?? "").localizedCaseInsensitiveContains(searchText) }
    }

    // オンラインかどうかは PresenceStore を見るので、WebSocket で出入りがあればすぐ並びが変わる
    private var online: [User] { filtered.filter { presence.isOnline($0.id) } }
    private var offline: [User] { filtered.filter { !presence.isOnline($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                if !online.isEmpty {
                    Section("オンライン — \(online.count)") {
                        ForEach(online) { memberRow($0) }
                    }
                }
                if !offline.isEmpty {
                    Section("オフライン — \(offline.count)") {
                        ForEach(offline) { memberRow($0) }
                    }
                }
            }
            .animation(.default, value: presence.onlineIds)
            .navigationTitle("メンバー")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "名前で検索")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
            .overlay {
                if !hasLoaded {
                    ProgressView()
                } else if let errorMessage {
                    ContentUnavailableView("読み込めませんでした", systemImage: "person.2.slash", description: Text(errorMessage))
                } else if !searchText.isEmpty, filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .sheet(item: $profileTarget) { target in
                ProfileView(userId: target.id)
                    .presentationDetents([.medium, .large])
            }
            .task { await load() }
        }
    }

    private func memberRow(_ user: User) -> some View {
        Button {
            profileTarget = MemberProfileTarget(id: user.id)
        } label: {
            HStack(spacing: 12) {
                PresenceIcon(userId: user.id, url: auth.client?.baseURL.appending(path: "user/icon/\(user.id)"))
                Text(user.name ?? "名前なし")
                    // オフラインの人は少し薄く
                    .foregroundStyle(presence.isOnline(user.id) ? .primary : .secondary)
                if user.isBot {
                    Text("BOT")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// 参加者を 50 人ずつ、最後まで取る（cursorUserId で続きを取る）
    private func load() async {
        guard let client = auth.client else { return }
        defer { hasLoaded = true }
        var all: [User] = []
        var cursor: String?
        do {
            while true {
                var query = [
                    URLQueryItem(name: "joinedChannel", value: channel.id),
                    URLQueryItem(name: "length", value: "50"),
                ]
                if let cursor {
                    query.append(URLQueryItem(name: "cursorUserId", value: cursor))
                }
                let page: [User] = try await client.get("user/list", query: query)
                all += page
                guard page.count == 50, let last = page.last else { break }
                cursor = last.id
            }
            members = all
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MemberProfileTarget: Identifiable {
    let id: String
}
