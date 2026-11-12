import SwiftUI

/// 画像を全画面で見る画面。
/// - ピンチで拡大・縮小、拡大中はドラッグで移動
/// - ダブルタップで拡大 / 元に戻す
/// - 拡大していないときは上下にスワイプで閉じる（写真アプリと同じ）
struct ImageViewer: View {
    let url: URL?
    let title: String

    @Environment(\.dismiss) private var dismiss

    /// 今の倍率と、ピンチを始めたときの倍率
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    /// 今のずらし量と、ドラッグを始めたときのずらし量
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    private var isZoomed: Bool { scale > 1 }

    var body: some View {
        NavigationStack {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnify.simultaneously(with: drag))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring) {
                            if isZoomed {
                                reset()
                            } else {
                                scale = 2.5
                                baseScale = 2.5
                            }
                        }
                    }
            } placeholder: {
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // スワイプで閉じるとき、離れるほど背景を透かす
            .background(.black.opacity(backgroundOpacity))
            .ignoresSafeArea()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
            }
        }
        // 背景が黒なので、ボタンや文字は暗い画面用の色にする
        .environment(\.colorScheme, .dark)
    }

    private var backgroundOpacity: Double {
        guard !isZoomed else { return 1 }
        return max(0.3, 1 - abs(offset.height) / 400)
    }

    /// ピンチで拡大・縮小
    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(1, baseScale * value.magnification)
            }
            .onEnded { _ in
                baseScale = scale
                if !isZoomed {
                    withAnimation(.spring) { reset() }
                }
            }
    }

    /// 拡大中は移動、拡大していなければスワイプで閉じる
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: baseOffset.width + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                if isZoomed {
                    baseOffset = offset
                } else if abs(value.translation.height) > 120 {
                    dismiss()
                } else {
                    withAnimation(.spring) { reset() }
                }
            }
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

#Preview {
    ImageViewer(url: URL(string: "https://example.com/image.png"), title: "image.png")
}
