import HygieiaDomain

public enum SunburstViewportBudget: Hashable, Sendable {
    case fallback
    case compact
    case regular
    case large

    public var maximumDepth: UInt16 {
        switch self {
        case .fallback: 0
        case .compact, .regular, .large: 1
        }
    }

    public var maximumNodeCount: Int {
        switch self {
        case .fallback: 1
        case .compact: 768
        case .regular: 1_536
        case .large: 2_048
        }
    }
}

public enum SunburstViewportPolicy {
    public static func budget(for viewport: SunburstViewport) -> SunburstViewportBudget {
        let outerRadius = min(viewport.width, viewport.height) / 2 - 12
        guard outerRadius.isFinite, outerRadius >= 72 else { return .fallback }
        if outerRadius < 220 { return .compact }
        if outerRadius < 420 { return .regular }
        return .large
    }

    public static func request(root: NodeID, metric: SunburstSizeMetric, viewport: SunburstViewport) -> SunburstProjectionRequest {
        let budget = budget(for: viewport)
        let outerRadius = min(viewport.width, viewport.height) / 2 - 12
        let centerRadius = min(max(outerRadius * 0.18, 44), 84)
        let usableRadius = max(0, outerRadius - centerRadius)
        let thickness = budget.maximumDepth == 0 ? 0 : usableRadius / Double(budget.maximumDepth)
        let spans = ContiguousArray((0..<Int(budget.maximumDepth)).map { offset in
            let depth = offset + 1
            let midRadius = centerRadius + (Double(depth) - 0.5) * thickness
            return max(Double.pi / 360, 3 / max(midRadius, .leastNonzeroMagnitude))
        })
        return .init(
            root: root,
            metric: metric,
            maximumDepth: budget.maximumDepth,
            maximumNodeCount: budget.maximumNodeCount,
            minimumAngularSpanByDepth: spans
        )
    }
}
