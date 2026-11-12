import SwiftUI

extension View {
    /// 上下反転する（左右はそのまま）。反転したスクロールの中で、各行を元の向きに戻すのにも使う
    func flippedUpsideDown() -> some View {
        scaleEffect(x: 1, y: -1)
    }
}
