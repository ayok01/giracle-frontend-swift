import SwiftUI

/// ユーザーのプロフィール（Web 版の UserinfoModalWrapper に相当）。シートで出す
struct ProfileView: View {
    let userId: String

    @Environment(AuthStore.self) private var auth
    @Environment(ChannelStore.self) private var channelStore
    @Environment(\.dismiss) private var dismiss

    @State private var user: User?
    @State private var roles: [Role] = []
    @State private var errorMessage: String?
    @State private var copied = false

    private var baseURL: URL? { auth.client?.baseURL }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let user {
                        details(user)
                    }
                }
            }
            .overlay {
                if user == nil {
                    if let errorMessage {
                        ContentUnavailableView("読み込めませんでした", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(errorMessage))
                    } else {
                        ProgressView()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    /// バナーとアイコン
    private var header: some View {
        // バナーの下端にアイコンを半分重ねる（X や Discord のプロフィールと同じ形）
        AsyncImage(url: baseURL?.appending(path: "user/banner/\(userId)")) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.tint.opacity(0.25))
        }
        .frame(height: 140)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            PresenceIcon(userId: userId, url: baseURL?.appending(path: "user/icon/\(userId)"), size: 80)
                .overlay(Circle().stroke(.background, lineWidth: 4))
                .offset(x: 20, y: 40)
        }
        .padding(.bottom, 40)
    }

    private func details(_ user: User) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(user.name ?? "名前なし")
                    .font(.title2.bold())
                if user.isBot {
                    Text("BOT")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint, in: .capsule)
                        .foregroundStyle(.white)
                }
                if user.isBanned == true {
                    Label("BAN", systemImage: "nosign")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }

            if let intro = user.selfIntroduction, !intro.isEmpty {
                Text(intro)
            }

            if let links = user.roleLinks, !links.isEmpty {
                section("ロール") {
                    FlowLayout(spacing: 6) {
                        ForEach(links, id: \.roleId) { link in
                            if let role = roles.first(where: { $0.id == link.roleId }) {
                                RoleChip(role: role)
                            }
                        }
                    }
                }
            }

            if let joins = user.channelJoins, !joins.isEmpty {
                section("参加チャンネル") {
                    FlowLayout(spacing: 6) {
                        ForEach(joins, id: \.channelId) { join in
                            if let channel = channelStore.allChannels.first(where: { $0.id == join.channelId }) {
                                Text(channel.name)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.fill.tertiary, in: .capsule)
                            }
                        }
                    }
                }
            }

            Button(copied ? "コピーしました" : "ユーザーIDをコピー", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = user.id
                copied = true
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func load() async {
        guard let client = auth.client else { return }
        do {
            user = try await client.get("user/info/\(userId)")
            roles = (try? await client.get("role/list")) ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 丸いユーザーアイコン
struct UserIcon: View {
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(.fill.tertiary)
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}

/// オンラインなら右下に緑の点が付くアイコン（Discord や Slack と同じ表し方）
struct PresenceIcon: View {
    let userId: String
    let url: URL?
    var size: CGFloat = 36

    @Environment(PresenceStore.self) private var presence

    var body: some View {
        UserIcon(url: url, size: size)
            .overlay(alignment: .bottomTrailing) {
                if presence.isOnline(userId) {
                    Circle()
                        .fill(.green)
                        .frame(width: size * 0.3, height: size * 0.3)
                        // 背景色の縁取りで、アイコンと点の境目を分かりやすく
                        .overlay(Circle().stroke(.background, lineWidth: max(2, size * 0.06)))
                        .accessibilityLabel("オンライン")
                }
            }
    }
}

/// ロールの名前を、そのロールの色で囲んで出す
private struct RoleChip: View {
    let role: Role

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: role.color) ?? .secondary)
                .frame(width: 8, height: 8)
            Text(role.name)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Color(hex: role.color) ?? .secondary, lineWidth: 1))
    }
}

extension Color {
    /// "#ff8800" や "#fff" から色を作る（CSS の色の書き方）
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
