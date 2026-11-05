import SwiftUI

/// The tail belongs to the last bubble in a sender's run. It extends into
/// the transcript gutter without changing the text's measurement or inset.
struct MessageBubbleShape: Shape {
    var isOwn: Bool
    var hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(Tokens.Bubble.radius, rect.height / 2)
        guard hasTail else { return Path(roundedRect: rect, cornerRadius: radius) }
        let x = rect.minX
        let y = rect.minY
        let right = rect.maxX
        let bottom = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: x + radius, y: y))
        path.addLine(to: CGPoint(x: right - radius, y: y))
        path.addQuadCurve(to: CGPoint(x: right, y: y + radius), control: CGPoint(x: right, y: y))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: x + radius, y: bottom))
        path.addCurve(to: CGPoint(x: x + 9, y: bottom + 6),
                      control1: CGPoint(x: x + 18, y: bottom),
                      control2: CGPoint(x: x + 5, y: bottom + 10))
        path.addCurve(to: CGPoint(x: x + 5, y: bottom - 8),
                      control1: CGPoint(x: x + 15, y: bottom),
                      control2: CGPoint(x: x + 9, y: bottom - 3))
        path.addQuadCurve(to: CGPoint(x: x, y: bottom - radius), control: CGPoint(x: x, y: bottom - 14))
        path.addLine(to: CGPoint(x: x, y: y + radius))
        path.addQuadCurve(to: CGPoint(x: x + radius, y: y), control: CGPoint(x: x, y: y))
        path.closeSubpath()
        if isOwn {
            path = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
        }
        return path
    }
}
