import SwiftUI

struct SettingsView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        NavigationStack {
            Form {
                Section("サーバー") {
                    LabeledContent("接続先", value: auth.serverHost)
                }

                Section {
                    Button("サインアウト", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await auth.signOut() }
                    }
                }
            }
            .navigationTitle("設定")
        }
    }
}

#Preview {
    SettingsView()
        .environment(AuthStore())
}
