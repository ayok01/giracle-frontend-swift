import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Environment(AuthStore.self) private var auth

    /// 自分のユーザー情報（読み込み前は nil）
    @State private var me: User?
    @State private var name = ""
    @State private var selfIntroduction = ""
    @State private var isSaving = false
    @State private var message: String?

    @State private var iconItem: PhotosPickerItem?
    /// アイコンを変えたら URL を変えて、古い画像のキャッシュを使わないようにする
    @State private var iconVersion = Date.now.timeIntervalSince1970
    @State private var isUploadingIcon = false
    @State private var bannerItem: PhotosPickerItem?
    @State private var bannerVersion = Date.now.timeIntervalSince1970
    @State private var isUploadingBanner = false
    @State private var isProfilePresented = false

    /// サーバー側の上限（Consts.ts の NAME_MAX_LENGTH と、自己紹介の maxLength）
    private let nameMaxLength = 64
    private let introMaxLength = 128

    private var hasChanges: Bool {
        guard let me else { return false }
        return name != (me.name ?? "") || selfIntroduction != (me.selfIntroduction ?? "")
    }

    private var canSave: Bool {
        hasChanges && !name.isEmpty && name.count <= nameMaxLength
            && selfIntroduction.count <= introMaxLength && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                profileSection

                Section("サーバー") {
                    if let config = auth.serverConfig {
                        ServerInfoView(config: config, baseURL: auth.client?.baseURL)
                    }
                    LabeledContent("接続先", value: auth.serverHost)
                }

                Section {
                    Button("サインアウト", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                }
            }
            .navigationTitle("設定")
            .task { await loadMe() }
            .sheet(isPresented: $isProfilePresented) {
                if let userId = auth.userId {
                    ProfileView(userId: userId)
                        .presentationDetents([.medium, .large])
                }
            }
            .alert(
                message ?? "",
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button("OK") {}
            }
        }
    }

    private var profileSection: some View {
        Section {
            // バナー。タップで写真を選んで変更
            PhotosPicker(selection: $bannerItem, matching: .images) {
                AsyncImage(url: versioned(path: "user/banner", version: bannerVersion)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.tint.opacity(0.25))
                }
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    Label(isUploadingBanner ? "アップロード中…" : "バナーを変更", systemImage: "photo")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .padding(8)
                }
            }
            .buttonStyle(.plain)
            .disabled(isUploadingBanner)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .onChange(of: bannerItem) { _, item in
                guard let item else { return }
                Task { await changeBanner(item) }
            }

            HStack(spacing: 16) {
                // アイコン。タップで写真を選んで変更
                PhotosPicker(selection: $iconItem, matching: .images) {
                    UserIcon(url: iconURL, size: 72)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: isUploadingIcon ? "arrow.triangle.2.circlepath" : "camera.fill")
                                .font(.caption)
                                .padding(6)
                                .background(.tint, in: .circle)
                                .foregroundStyle(.white)
                        }
                }
                .buttonStyle(.plain)
                .disabled(isUploadingIcon)
                .onChange(of: iconItem) { _, item in
                    guard let item else { return }
                    Task { await changeIcon(item) }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(me?.name ?? "…")
                        .font(.headline)
                    Button("プロフィールを表示") {
                        isProfilePresented = true
                    }
                    .font(.subheadline)
                }
            }
            .padding(.vertical, 4)

            TextField("名前", text: $name)
                .textContentType(.nickname)
            // 自己紹介は複数行。文字数の上限を超えたら赤くする
            VStack(alignment: .trailing) {
                TextField("自己紹介", text: $selfIntroduction, axis: .vertical)
                    .lineLimit(2...5)
                Text("\(selfIntroduction.count) / \(introMaxLength)")
                    .font(.caption)
                    .foregroundStyle(selfIntroduction.count > introMaxLength ? .red : .secondary)
            }

            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("プロフィールを保存")
                }
            }
            .disabled(!canSave)
        } header: {
            Text("プロフィール")
        }
    }

    private var iconURL: URL? {
        versioned(path: "user/icon", version: iconVersion)
    }

    /// 自分の画像の URL。変更したら version を変えて、古い画像のキャッシュを使わないようにする
    private func versioned(path: String, version: TimeInterval) -> URL? {
        guard let userId = auth.userId else { return nil }
        return auth.client?.baseURL
            .appending(path: "\(path)/\(userId)")
            .appending(queryItems: [URLQueryItem(name: "v", value: String(Int(version)))])
    }

    private func loadMe() async {
        guard let client = auth.client, let userId = auth.userId,
              let user: User = try? await client.get("user/info/\(userId)")
        else { return }
        me = user
        name = user.name ?? ""
        selfIntroduction = user.selfIntroduction ?? ""
    }

    private func save() async {
        guard let client = auth.client else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.post(
                "user/profile-update",
                body: ProfileUpdateRequest(name: name, selfIntroduction: selfIntroduction)
            )
            await loadMe()
            message = "プロフィールを保存しました"
        } catch {
            message = error.localizedDescription
        }
    }

    private func changeIcon(_ item: PhotosPickerItem) async {
        guard let client = auth.client else { return }
        isUploadingIcon = true
        defer {
            isUploadingIcon = false
            iconItem = nil
        }
        // 添付画像と同じ変換（HEIC → JPEG、PNG/GIF はそのまま）。サーバーは PNG/GIF/JPEG の 8MB まで
        guard let image = await PendingAttachment.load(from: item) else {
            message = "画像を読み込めませんでした"
            return
        }
        do {
            try await client.upload(
                "user/change-icon",
                fileField: "icon",
                file: image.data,
                fileName: image.fileName,
                mimeType: image.mimeType
            )
            iconVersion = Date.now.timeIntervalSince1970
        } catch {
            message = error.localizedDescription
        }
    }
}

extension SettingsView {
    /// バナーを変える。サーバーは PNG/GIF/JPEG の 10MB まで（user.service.ts の ChangeBanner）
    private func changeBanner(_ item: PhotosPickerItem) async {
        guard let client = auth.client else { return }
        isUploadingBanner = true
        defer {
            isUploadingBanner = false
            bannerItem = nil
        }
        guard let image = await PendingAttachment.load(from: item) else {
            message = "画像を読み込めませんでした"
            return
        }
        do {
            try await client.upload(
                "user/change-banner",
                fileField: "banner",
                file: image.data,
                fileName: image.fileName,
                mimeType: image.mimeType
            )
            bannerVersion = Date.now.timeIntervalSince1970
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct ProfileUpdateRequest: Encodable {
    let name: String
    let selfIntroduction: String
}

#Preview {
    SettingsView()
        .environment(AuthStore())
}
