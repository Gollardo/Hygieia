import Foundation

enum ScanPhase: Equatable, Sendable {
    case idle
    case choosingFolder
    case preparing
    case scanning
    case cancelling
    case completed
    case completedWithIssues
    case cancelled
    case failed

    var isActive: Bool {
        self == .preparing || self == .scanning || self == .cancelling
    }
}

enum SizeMetric: String, CaseIterable, Sendable {
    case reportedAllocated
    case logical

    var title: String {
        switch self {
        case .reportedAllocated: "Allocated (reported)"
        case .logical: "Logical"
        }
    }
}
