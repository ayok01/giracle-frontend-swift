import SwiftUI

/// サーバーのバナー・名前・紹介文
struct ServerInfoView: View {
    let config: ServerConfig
    let baseURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: baseURL?.appending(path: "server/banner")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.tint.opacity(0.25))
            }
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 12))

            Text(config.name)
                .font(.headline)
            if !config.introduction.isEmpty {
                Text(config.introduction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
