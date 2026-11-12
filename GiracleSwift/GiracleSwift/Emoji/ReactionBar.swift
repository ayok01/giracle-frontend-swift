import SwiftUI

/// メッセージの下に並ぶリアクション（絵文字 + 人数）。タップで付けたり外したり
struct ReactionBar: View {
    let reactions: [ReactionSummary]
    let onToggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(reactions, id: \.emojiCode) { reaction in
                Button {
                    onToggle(reaction.emojiCode)
                } label: {
                    HStack(spacing: 4) {
                        EmojiView(code: reaction.emojiCode, size: 16)
                        Text(reaction.count, format: .number)
                            .font(.caption.monospacedDigit())
                            .contentTransition(.numericText())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    // 自分が付けたものはアプリの色で囲む
                    .background(
                        reaction.includingYou ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.fill.tertiary),
                        in: .capsule
                    )
                    .overlay {
                        if reaction.includingYou {
                            Capsule().strokeBorder(.tint, lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy, value: reactions)
    }
}

/// 横に並べて、入りきらなければ次の行へ折り返すレイアウト（CSS の flex-wrap: wrap 相当）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// 子要素を幅に収まるように行へ振り分ける
    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if nextWidth > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
