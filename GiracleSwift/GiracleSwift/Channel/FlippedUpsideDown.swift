import SwiftUI

extension View {
    /// 上下反転する（左右はそのまま）。反転したスクロールの中で、各行を元の向きに戻すのにも使う。
    /// 注意: 反転した中では標準の長押しメニュー（contextMenu）の浮かび上がる演出が崩れる
    /// （回転で反転しても同じだった）ので、チャンネル画面では使わずシートで代用している
    func flippedUpsideDown() -> some View {
        scaleEffect(x: 1, y: -1)
    }
}
