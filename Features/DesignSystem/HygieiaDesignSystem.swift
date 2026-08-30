import SwiftUI

enum HygieiaPalette {
    static let canvas = Color(red: 0.025, green: 0.038, blue: 0.052)
    static let canvasRaised = Color(red: 0.040, green: 0.058, blue: 0.075)
    static let panel = Color(red: 0.055, green: 0.072, blue: 0.090)
    static let panelRaised = Color(red: 0.075, green: 0.094, blue: 0.116)
    static let separator = Color.white.opacity(0.085)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.58)
    static let glacier = Color(red: 0.52, green: 0.70, blue: 0.96)
    static let glacierDim = Color(red: 0.28, green: 0.42, blue: 0.61)
    static let aqua = Color(red: 0.34, green: 0.87, blue: 0.82)
    static let coral = Color(red: 1.00, green: 0.43, blue: 0.36)
    static let amber = Color(red: 0.96, green: 0.68, blue: 0.29)
    static let destructive = Color(red: 0.88, green: 0.25, blue: 0.22)
}

enum HygieiaSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
}

enum HygieiaRadius {
    static let control: CGFloat = 8
    static let panel: CGFloat = 14
    static let hero: CGFloat = 18
}

struct HygieiaBrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        Image("HygieiaBrandMark")
            .resizable()
            .interpolation(.high)
            .blendMode(.screen)
            .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct HygieiaAtmosphere: View {
    var intensity: Double = 1
    var animated = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        GeometryReader { proxy in
            Image("LustralNebula")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(animated && !reduceMotion && isExpanded ? 1.035 : 1)
                .opacity(0.88 * intensity)
                .blendMode(.screen)
                .overlay {
                    LinearGradient(
                        colors: [
                            HygieiaPalette.canvas.opacity(0.82),
                            HygieiaPalette.canvas.opacity(0.05),
                            HygieiaPalette.canvas.opacity(0.30)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .overlay {
                    LinearGradient(
                        colors: [
                            HygieiaPalette.canvas.opacity(0.50),
                            .clear,
                            HygieiaPalette.canvas.opacity(0.72)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .animation(
                    animated && !reduceMotion
                        ? .easeInOut(duration: 6).repeatForever(autoreverses: true)
                        : nil,
                    value: isExpanded
                )
                .onAppear { isExpanded = animated && !reduceMotion }
                .onChange(of: reduceMotion) { _, next in
                    isExpanded = animated && !next
                }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

struct HygieiaBrandLockup: View {
    var compact = false

    var body: some View {
        HStack(spacing: 9) {
            HygieiaBrandMark(size: compact ? 27 : 38)
            VStack(alignment: .leading, spacing: compact ? 0 : 2) {
                Text("Hygieia")
                    .font(compact ? .headline : .title2.weight(.semibold))
                    .foregroundStyle(HygieiaPalette.textPrimary)
                if !compact {
                    Text("See clearly. Clear safely.")
                        .font(.caption)
                        .foregroundStyle(HygieiaPalette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hygieia. See clearly. Clear safely.")
    }
}

struct HygieiaPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: HygieiaRadius.panel, style: .continuous)
                    .fill(HygieiaPalette.panel.opacity(0.94))
                    .overlay {
                        RoundedRectangle(cornerRadius: HygieiaRadius.panel, style: .continuous)
                            .stroke(HygieiaPalette.separator, lineWidth: 1)
                    }
            )
    }
}

struct HygieiaSectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HygieiaSpacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(HygieiaPalette.textPrimary)
            Spacer(minLength: HygieiaSpacing.small)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HygieiaPalette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

struct HygieiaStatusPill: View {
    let systemImage: String
    let title: String
    var tint: Color = HygieiaPalette.aqua

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(HygieiaPalette.textSecondary)
            .symbolRenderingMode(.hierarchical)
            .tint(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(HygieiaPalette.panelRaised.opacity(0.72), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

extension View {
    func hygieiaSectionPadding() -> some View {
        padding(HygieiaSpacing.large)
    }
}
