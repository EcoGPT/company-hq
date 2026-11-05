import SwiftUI

// Layout, hover paint, and hit testing share the same shape and inset.
struct PlanningButtonStyle: ButtonStyle {
  enum Shape {
    case card, capsule
    var outline: AnyShape {
      switch self {
      case .card:
        AnyShape(RoundedRectangle(cornerRadius: Tokens.Glass.cardRadius, style: .continuous))
      case .capsule: AnyShape(Capsule())
      }
    }
  }
  var isFullWidth = false
  var shape: Shape = .capsule
  var highlightsHover = true
  func makeBody(configuration: Configuration) -> some View {
    PlanningButtonBody(
      configuration: configuration, isFullWidth: isFullWidth, shape: shape,
      highlightsHover: highlightsHover)
  }
}

private struct PlanningButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let isFullWidth: Bool
  let shape: PlanningButtonStyle.Shape
  let highlightsHover: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false
  var body: some View {
    configuration.label
      .padding(.horizontal, Tokens.Space.x4)
      .padding(.vertical, shape == .card ? Tokens.Space.x4 : Tokens.Space.x3)
      .frame(maxWidth: isFullWidth ? .infinity : nil, alignment: .leading)
      .frame(minHeight: 44)
      .background(
        highlightsHover && isEnabled && (isHovering || configuration.isPressed)
          ? Tokens.Palette.surfaceHover : Color.clear,
        in: shape.outline
      )
      .contentShape(shape.outline)
      .clipShape(shape.outline)
      .onHover { isHovering = $0 }
  }
}
