import SwiftUI

/// メッセージ本文の下に出す、添付ファイルと URL プレビュー
struct MessageAttachments: View {
    let message: Message
    /// 画像ファイルId → 縦横サイズ
    let imageDimensions: [String: ImageDimension]
    let baseURL: URL?

    /// タップされた画像（nil でなければ全画面で表示する）
    @State private var selectedImage: MessageFile?
    /// 一覧の画像と全画面の画像を「同じもの」として結び付け、拡大するアニメーションにするための名前空間
    @Namespace private var namespace

    var body: some View {
        // ForEach や Group に付けた modifier は中の各要素に付いてしまうので、
        // fullScreenCover を1つだけ付けるために VStack でまとめる
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.files ?? []) { file in
                if file.isImage {
                    AttachedImage(url: fileURL(file), dimension: imageDimensions[file.id])
                        .matchedTransitionSource(id: file.id, in: namespace)
                        .onTapGesture {
                            selectedImage = file
                        }
                } else {
                    AttachedFileRow(file: file)
                }
            }
            ForEach(message.urlPreviews ?? []) { preview in
                UrlPreviewCard(preview: preview, baseURL: baseURL)
            }
        }
        .fullScreenCover(item: $selectedImage) { file in
            ImageViewer(url: fileURL(file), title: file.actualFileName)
                // タップした画像からズームして開き、閉じるとその場所へ戻る
                .navigationTransition(.zoom(sourceID: file.id, in: namespace))
        }
    }

    private func fileURL(_ file: MessageFile) -> URL? {
        baseURL?.appending(path: "message/file/\(file.id)")
    }
}

/// 添付画像。サイズが分かっていれば読み込む前から同じ縦横比の枠を確保して、表示がガタつかないようにする
private struct AttachedImage: View {
    let url: URL?
    let dimension: ImageDimension?

    private let maxSide: CGFloat = 260

    var body: some View {
        // 枠（縦横比だけ決めた透明な四角）を作って、その上に画像を重ねる
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: maxSide, maxHeight: maxSide)
            .overlay {
                // URLSession.shared を使うので Cookie も送られる（ファイル取得は認証が必要）
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(.fill.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: 12))
    }

    /// 横 ÷ 縦。分からなければ 4:3 で仮置き
    private var aspectRatio: CGFloat {
        guard let dimension, dimension.height > 0 else { return 4 / 3 }
        return dimension.width / dimension.height
    }
}

/// 画像以外の添付ファイル
private struct AttachedFileRow: View {
    let file: MessageFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.actualFileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Int64(file.size), format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }
}

/// リンクのプレビューカード（OGP）。タップでブラウザを開く
private struct UrlPreviewCard: View {
    let preview: UrlPreview
    let baseURL: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: preview.url) {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let imageURL = thumbnailURL(preview.imageLink) {
                    AsyncImage(url: imageURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.fill.tertiary)
                    }
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay {
                        // 動画のリンクなら再生マークを重ねる
                        if preview.videoLink != nil {
                            Image(systemName: "play.circle.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        AsyncImage(url: thumbnailURL(preview.faviconLink, forFavicon: true)) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: "link")
                        }
                        .frame(width: 16, height: 16)

                        Text(preview.title)
                            .font(.subheadline.bold())
                            .lineLimit(2)
                    }
                    if let description = preview.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: 300, alignment: .leading)
            .background(.fill.quaternary)
            .clipShape(.rect(cornerRadius: 12))
        }
        // ボタンの見た目（青い文字など）を付けず、カードの見た目のまま
        .buttonStyle(.plain)
    }

    /// 外部サイトの画像を、サーバーの縮小 API（Web 版と同じ /message/url-thumbnail）経由で取る
    private func thumbnailURL(_ link: String?, forFavicon: Bool = false) -> URL? {
        guard let link, !link.isEmpty else { return nil }
        var items = [URLQueryItem(name: "targetUrl", value: link)]
        if forFavicon {
            items.append(URLQueryItem(name: "forFavicon", value: "true"))
        }
        return baseURL?.appending(path: "message/url-thumbnail").appending(queryItems: items)
    }
}
