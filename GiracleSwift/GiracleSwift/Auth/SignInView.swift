import SwiftUI

struct SignInView: View {
    @Environment(AuthStore.self) private var auth

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var auth = auth

        NavigationStack {
            Form {
                Section {
                    TextField("localhost:3000", text: $auth.serverHost)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("サーバー")
                } footer: {
                    Text("ドメインだけ入力してください（例: localhost:3000）")
                }

                // 入力したドメインのサーバーが見つかれば、名前と紹介文を出す（正しく入力できたかの確認にもなる）
                if let config = auth.serverConfig {
                    Section {
                        ServerInfoView(config: config, baseURL: auth.client?.baseURL)
                    }
                }

                Section("アカウント") {
                    TextField("ユーザー名", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Giracle")
            // ドメインを打ち終わって 0.5 秒たったらサーバーの情報を取りに行く（打つたびに通信しないため。debounce）。
            // task(id:) は id が変わると前の処理をキャンセルしてやり直すので、打ち続けている間は待ちがリセットされる
            .task(id: auth.serverHost) {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await auth.loadServerConfig()
            }
            .animation(.default, value: auth.serverConfig)
            // 画面下に浮かぶ Liquid Glass のボタン
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await signIn() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("サインイン").bold()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(auth.serverHost.isEmpty || username.isEmpty || password.count < 4 || isLoading)
                .padding(.horizontal)
            }
        }
    }

    private func signIn() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await auth.signIn(username: username, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SignInView()
        .environment(AuthStore())
}
