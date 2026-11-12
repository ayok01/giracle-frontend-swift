import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// 送信前の添付画像（写真アプリから選んだもの）
struct PendingAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let fileName: String
    let mimeType: String
    let width: Double
    let height: Double
    /// 入力欄の上に出す小さなプレビュー
    let thumbnail: Image
}

extension PendingAttachment {
    /// 写真アプリで選ばれたものを、送れる形に変換する。
    /// - GIF と PNG はそのまま（アニメーションや透明を保つ）
    /// - それ以外（iPhone の写真は HEIC が多い）は JPEG にする。
    ///   HEIC は Web 版のブラウザで表示できないことがあるのと、
    ///   JPEG にし直すと位置情報などのメタデータも落ちるため
    static func load(from item: PhotosPickerItem) async -> PendingAttachment? {
        guard let original = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: original)
        else { return nil }

        let types = item.supportedContentTypes
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacing(":", with: "")

        let data: Data
        let ext: String
        let mimeType: String
        if types.contains(where: { $0.conforms(to: .gif) }) {
            (data, ext, mimeType) = (original, "gif", "image/gif")
        } else if types.contains(where: { $0.conforms(to: .png) }) {
            (data, ext, mimeType) = (original, "png", "image/png")
        } else if let jpeg = image.jpegData(compressionQuality: 0.9) {
            (data, ext, mimeType) = (jpeg, "jpg", "image/jpeg")
        } else {
            return nil
        }

        return PendingAttachment(
            data: data,
            fileName: "photo-\(stamp).\(ext)",
            mimeType: mimeType,
            width: image.size.width * image.scale,
            height: image.size.height * image.scale,
            thumbnail: Image(uiImage: image)
        )
    }
}
