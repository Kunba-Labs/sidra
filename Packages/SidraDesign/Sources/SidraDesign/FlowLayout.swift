import SwiftUI

/// Lays its children out left to right and wraps to a new line when the next one does not fit.
public struct FlowLayout: Layout {
    public var spacing: CGFloat = 6
    public init(spacing: CGFloat = 6) { self.spacing = spacing }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var i = 0
        for r in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for _ in 0..<r.count {
                let s = subviews[i].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + r.y), proposal: .init(width: min(s.width, bounds.width), height: s.height))
                x += min(s.width, bounds.width) + spacing; i += 1
            }
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(count: Int, y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(count: Int, y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0, n = 0
        for v in subviews {
            let s = v.sizeThatFits(.init(width: width, height: nil))
            if n > 0 && x + spacing + s.width > width {
                rows.append((n, y, x, h)); y += h + spacing; x = 0; h = 0; n = 0
            }
            x += (n > 0 ? spacing : 0) + min(s.width, width); h = max(h, s.height); n += 1
        }
        if n > 0 { rows.append((n, y, x, h)) }
        return rows
    }
}
